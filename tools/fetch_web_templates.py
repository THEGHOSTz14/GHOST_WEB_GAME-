#!/usr/bin/env python3
"""Extract only selected members from a remote zip (Godot .tpz) using HTTP range
requests, so the 1.2 GB export-template archive never has to be downloaded whole.

Usage:
    python fetch_web_templates.py --list
    python fetch_web_templates.py                 # web templates only
    python fetch_web_templates.py --pattern os/linux
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import struct
import time
import subprocess
import sys
import zipfile
import zlib

GODOT_VERSION = "4.7.2"
STABILITY = "stable"
TPZ_URL = (
    "https://github.com/godotengine/godot/releases/download/"
    f"{GODOT_VERSION}-{STABILITY}/"
    f"Godot_v{GODOT_VERSION}-{STABILITY}_export_templates.tpz"
)

CHUNK = 8 * 1024 * 1024
CURL = shutil.which("curl") or "curl"


def templates_dir() -> str:
    if os.name == "nt":
        base = os.environ.get("APPDATA", os.path.expanduser("~"))
    else:
        base = os.path.join(os.environ.get("XDG_DATA_HOME",
                                           os.path.expanduser("~/.local/share")))
    return os.path.join(base, "Godot", "export_templates",
                        f"{GODOT_VERSION}.{STABILITY}")


def _curl_slice(url: str, start: int, end: int, dest: str) -> None:
    """One byte range to a file. --speed-time aborts a stalled pipe so the
    caller's resume loop can retry instead of hanging for minutes. Transient DNS
    failures (curl exit 6) are not covered by --retry-all-errors on every build,
    so the whole chunk is retried here too."""
    cmd = [CURL, "-sS", "--fail", "--location", "--connect-timeout", "25",
           "--speed-limit", "5000", "--speed-time", "45", "--retry", "6",
           "--retry-all-errors", "--retry-delay", "3",
           "-H", "User-Agent: godot-template-fetch",
           "-r", f"{start}-{end}", "-o", dest, url]
    for attempt in range(12):
        try:
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
            return
        except subprocess.CalledProcessError as exc:
            if attempt == 11:
                raise
            wait = min(5 * (attempt + 1), 40)
            print(f"    curl exit {exc.returncode} at {start}, retry in {wait}s",
                  flush=True)
            time.sleep(wait)


def read_range(url: str, start: int, end: int) -> bytes:
    tmp = f".slice-{start}.tmp"
    _curl_slice(url, start, end, tmp)
    data = open(tmp, "rb").read()
    os.remove(tmp)
    if len(data) != end - start + 1:
        raise OSError(f"short read {len(data)} != {end - start + 1}")
    return data


def remote_size(url: str) -> int:
    # HEAD hangs behind GitHub's signed asset redirect, so ask for one byte and
    # read the total back out of Content-Range.
    tmp = ".probe.tmp"
    cmd = [CURL, "-sS", "--fail", "--location", "--connect-timeout", "25",
           "--speed-limit", "5000", "--speed-time", "45", "--retry", "6",
           "--retry-all-errors", "--retry-delay", "3",
           "-H", "User-Agent: godot-template-fetch",
           "-r", "0-0", "-D", ".probe.h", "-o", tmp, url]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    headers = open(".probe.h", encoding="latin-1").read().lower()
    for f in (tmp, ".probe.h"):
        if os.path.exists(f):
            os.remove(f)
    for line in headers.splitlines():
        if line.startswith("content-range:"):
            return int(line.rsplit("/", 1)[1].strip())
    raise OSError("server did not return Content-Range for a 1 byte request")


class RemoteZip:
    """Reads just enough of a remote zip to list members and stream one at a time."""

    def __init__(self, url: str) -> None:
        self.url = url
        self.size = remote_size(url)
        tail = read_range(url, self.size - min(self.size, 65_557), self.size - 1)
        eocd = tail.rfind(b"PK\x05\x06")
        if eocd < 0:
            raise OSError("no end-of-central-directory found")
        # EOCD: total entries @+10 (H), cd size @+12 (I), cd offset @+16 (I)
        entries = struct.unpack_from("<H", tail, eocd + 10)[0]
        cd_size = struct.unpack_from("<I", tail, eocd + 12)[0]
        cd_off = struct.unpack_from("<I", tail, eocd + 16)[0]
        if 0xFFFF in (entries,) or 0xFFFFFFFF in (cd_size, cd_off):
            loc = tail.rfind(b"PK\x06\x07", 0, eocd)
            if loc < 0:
                raise OSError("zip64 central directory locator missing")
            # locator: cd disk @+4 (I), zip64-eocd offset @+8 (Q)
            z64_off = struct.unpack_from("<Q", tail, loc + 8)[0]
            rec = read_range(url, z64_off, z64_off + 55)
            if rec[:4] != b"PK\x06\x06":
                raise OSError("bad zip64 end-of-central-directory")
            entries = struct.unpack_from("<Q", rec, 32)[0]
            cd_size = struct.unpack_from("<Q", rec, 40)[0]
            cd_off = struct.unpack_from("<Q", rec, 48)[0]
        self.entries = self._read_central_dir(cd_off, cd_size, entries)

    def _read_central_dir(self, off: int, size: int, count: int) -> dict[str, dict]:
        blob = b""
        step = 1 << 22
        for a in range(off, off + size, step):
            blob += read_range(self.url, a, min(a + step - 1, off + size - 1))
        out: dict[str, dict] = {}
        p = 0
        for _ in range(count):
            if blob[p : p + 4] != b"PK\x01\x02":
                raise OSError("corrupt central directory")
            # @+10 method, @+12 time, @+14 date, @+16 crc, @+20 csize, @+24 usize,
            # @+28 name len, @+30 extra len   |   @+42 local header offset
            method, _, _, crc, csize, usize, nlen, elen = struct.unpack_from(
                "<HHHIIIHH", blob, p + 10)
            lho = struct.unpack_from("<I", blob, p + 42)[0]
            name = blob[p + 46 : p + 46 + nlen].decode("utf-8", "replace")
            p += 46 + nlen + elen + struct.unpack_from("<H", blob, p + 32)[0]
            out[name] = {"method": method, "crc": crc, "csize": csize,
                         "usize": usize, "lho": lho}
        return out

    def stream_member(self, name: str, dest: str) -> None:
        e = self.entries[name]
        # Local header is variable length; 512 bytes always covers the fixed part.
        lh = read_range(self.url, e["lho"], e["lho"] + 511)
        if lh[:4] != b"PK\x03\x04":
            raise OSError(f"{name}: local header signature missing")
        nlen, elen = struct.unpack("<HH", lh[26:30])
        data_start = e["lho"] + 30 + nlen + elen
        raw = dest + ".part"
        have = os.path.getsize(raw) if os.path.exists(raw) else 0
        if have > e["csize"]:
            os.remove(raw)
            have = 0
        print(f"  {name}  {e['csize']/1048576:.1f} MB"
              f"  {'resume' if have else 'start'} at {have/1048576:.1f} MB", flush=True)
        with open(raw, "ab") as f:
            while have < e["csize"]:
                n = min(CHUNK, e["csize"] - have)
                tmp = raw + ".chunk"
                _curl_slice(self.url, data_start + have, data_start + have + n - 1, tmp)
                blob = open(tmp, "rb").read()
                os.remove(tmp)
                if len(blob) != n:
                    raise OSError(f"{name}: chunk {have}+{n} returned {len(blob)} bytes")
                f.write(blob)
                f.flush()
                have += n
                print(f"    {have/1048576:.0f}/{e['csize']/1048576:.0f} MB", flush=True)
        if e["method"] == zlib.DEFLATED:
            d, crc = zlib.decompressobj(-15), 0
            with open(raw, "rb") as src, open(dest, "wb") as dst:
                while chunk := src.read(1 << 20):
                    out = d.decompress(chunk)
                    crc = zlib.crc32(out, crc)
                    dst.write(out)
                if d.unconsumed_tail or not d.eof:
                    raise OSError(f"{name}: deflate stream truncated")
            os.remove(raw)
        else:
            crc = 0
            with open(raw, "rb") as src:
                while chunk := src.read(1 << 20):
                    crc = zlib.crc32(chunk, crc)
            shutil.move(raw, dest)
        if crc & 0xFFFFFFFF != e["crc"] or os.path.getsize(dest) != e["usize"]:
            os.remove(dest)
            raise OSError(f"{name}: CRC/size mismatch, download is corrupt")
        if zipfile.is_zipfile(dest):
            bad = zipfile.ZipFile(dest).testzip()
            if bad:
                raise OSError(f"{name}: inner zip entry {bad} failed CRC check")
        print(f"    ok  {os.path.getsize(dest)/1048576:.1f} MB  crc {crc & 0xFFFFFFFF:08x}",
              flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default=TPZ_URL)
    ap.add_argument("--pattern", default=r"(^|/)web_",
                    help=r"regex over member paths; default grabs web templates")
    ap.add_argument("--dest", default=None)
    ap.add_argument("--list", action="store_true", help="list members and exit")
    a = ap.parse_args()

    print(f"opening remote archive: {a.url}")
    z = RemoteZip(a.url)
    rx = re.compile(a.pattern)
    picked = sorted(n for n in z.entries if rx.search(n))
    if a.list:
        for n, e in sorted(z.entries.items()):
            print(f"{e['csize']/1048576:9.1f} MB  {'*' if n in picked else ' '}  {n}")
        print(f"\n{len(picked)} of {len(z.entries)} members match {a.pattern!r}")
        return 0
    if not picked:
        print("nothing matched -- try --list", file=sys.stderr)
        return 1
    dest_dir = a.dest or templates_dir()
    os.makedirs(dest_dir, exist_ok=True)
    for stale in os.listdir(dest_dir):
        if stale.endswith(".part") or stale.endswith(".chunk"):
            os.remove(os.path.join(dest_dir, stale))
    total = sum(z.entries[n]["csize"] for n in picked) / 1048576
    print(f"downloading {len(picked)} members (~{total:.0f} MB) into\n  {dest_dir}")
    for name in picked:
        # Godot expects templates flat in <version>.stable/, prefix stripped.
        leaf = os.path.basename(name)
        target = os.path.join(dest_dir, leaf)
        if os.path.exists(target):
            print(f"  skip {leaf} (already present)")
            continue
        z.stream_member(name, target)
    print(f"\ndone -> {dest_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
