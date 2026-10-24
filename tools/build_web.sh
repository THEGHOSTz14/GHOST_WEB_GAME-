#!/usr/bin/env bash
# Headless web export -> builds/web/ (loose files) + builds/y8/<name>.zip.
#
#   tools/build_web.sh                 release build
#   tools/build_web.sh --debug         debug templates (slower, has console dump)
#   tools/build_web.sh --gz            also emit .gz siblings + a .gz zip
#   GODOT_BIN=/path/to/godot tools/build_web.sh
#
# Fails loudly if the export came out threaded, because a threaded build only
# works on hosts that send COOP/COEP headers -- which y8 does not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="release"
GZ=0
for arg in "$@"; do
	case "$arg" in
		--debug) MODE="debug" ;;
		--gz) GZ=1 ;;
		*) echo "unknown flag: $arg" >&2; exit 2 ;;
	esac
done

find_godot() {
	if [ -n "${GODOT_BIN:-}" ] && [ -x "${GODOT_BIN}" ]; then echo "${GODOT_BIN}"; return 0; fi
	local cand
	for cand in \
		"/c/Users/Asus/AppData/Local/Programs/Godot/Godot_v4.7.2-stable_win64_console.exe" \
		"/c/Users/Asus/AppData/Local/Programs/Godot/Godot_v4.7.2-stable_win64.exe" \
		"$(command -v godot 2>/dev/null || true)" \
		"/Applications/Godot.app/Contents/MacOS/Godot"; do
		if [ -n "$cand" ] && [ -x "$cand" ]; then echo "$cand"; return 0; fi
	done
	return 1
}

GODOT="$(find_godot || true)"
if [ -z "${GODOT}" ]; then
	cat >&2 <<'MSG'
Godot not found. Set GODOT_BIN to your Godot 4.7 binary, or run:
  python tools/fetch_web_templates.py --help   (templates are a separate download)
MSG
	exit 1
fi

OUT="${ROOT}/builds/web"
rm -rf "${OUT}"
mkdir -p "${OUT}"

echo "== exporting (${MODE}) with ${GODOT##*/}"
"${GODOT}" --headless --path "${ROOT}" \
	"--export-${MODE}" "Web" "builds/web/index.html" 2>&1 | grep -vE '^\[' || true

cd "${OUT}"
[ -f index.html ] || { echo "FATAL: index.html missing -- export failed" >&2; exit 1; }

# The bridge is a page asset, not a Godot resource: copied beside the html.
cp "${ROOT}/platform/y8_bridge.js" "${OUT}/"

echo "== artefacts"
for f in index.html index.js index.wasm index.pck y8_bridge.js; do
	[ -f "$f" ] || { echo "FATAL: expected $f missing" >&2; exit 1; }
	printf "   %-22s %8.1f MB\n" "$f" "$(stat -c %s "$f" | awk '{print $1/1048576}')"
done

if grep -q "GODOT_THREADS_ENABLED = true" index.html; then
	echo "FATAL: export is threaded. y8 does not send COOP/COEP headers," >&2
	echo "       so this build would white-screen on the portal. Set" >&2
	echo "       variant/thread_support=false in export_presets.cfg." >&2
	exit 1
fi
echo "== single-threaded export confirmed"

TOTAL_KB=$(du -sk . | cut -f1)
echo "== total $(awk -v k="$TOTAL_KB" 'BEGIN{printf "%.1f", k/1024}') MB unpacked (the wasm dominates; transfer size is the zip)"

if [ "$GZ" = "1" ]; then
	for f in index.html index.js index.wasm index.pck; do
		gzip -9 -k -f "$f"
	done
fi

python - "${ROOT}" "${MODE}" "${GZ}" <<'PY'
import os, sys, zipfile
root, mode, gz = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
src = os.path.join(root, "builds", "web")
dst_dir = os.path.join(root, "builds", "y8")
os.makedirs(dst_dir, exist_ok=True)
dst = os.path.join(dst_dir, f"drone-vs-droids-{mode}.zip")
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
	for name in sorted(os.listdir(src)):
		path = os.path.join(src, name)
		if os.path.isfile(path) and (not name.endswith(".gz") or not gz):
			z.write(path, name)   # arcname = bare name: index.html sits at root
print(f"== wrote {dst} ({os.path.getsize(dst)/1048576:.1f} MB)")
PY

# builds/web is the cwd at this point, so anchor to the project root
ZIP="${ROOT}/builds/y8/drone-vs-droids-${MODE}.zip"
BYTES=$(stat -c %s "${ZIP}")
if [ "${BYTES}" -gt 20971520 ]; then
	echo "WARNING: ${BYTES} transferred exceeds the 20 MB Phase 4 budget" >&2
else
	awk -v b="${BYTES}" 'BEGIN{printf "== %.1f MB transferred, inside the 20 MB budget\n", b/1048576}'
fi

echo "== done. test with: python tools/serve_web.py"
