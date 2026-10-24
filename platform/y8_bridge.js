/* DvDY8 -- thin bridge between the Godot game and the y8 minimal SDK v2.
 *
 * Godot calls into this through JavaScriptBridge.eval(); async results go back
 * as a queue that GDScript drains with poll(). One-way calls plus polling avoid
 * depending on Godot's extension-callback registration, whose shape has changed
 * across point releases.
 *
 * IDs stay here (they are public page-side values) and in the y8 portal, never
 * inside the shipped .pck.
 *
 * Reference: https://cdn.y8.com/minimal-sdk/2-0/y8.min.js
 *            https://docs.y8.com  /  https://developer.y8.com
 */
(function () {
	"use strict";

	var CFG = window.DVD_Y8_CONFIG || {};
	var APP_ID = CFG.appId || "";
	var GAME_ID = CFG.gameId || "";
	var TABLE = CFG.leaderboard || "best-score";
	var AD_TIMEOUT_MS = CFG.adTimeoutMs || 20000;

	var sdk = null;
	var initialised = false;
	var adsOk = false;
	var adInFlight = false;
	var events = [];

	function push(evt) {
		events.push(evt);
	}

	function fakeReward() {
		// No SDK present (local dev, ad blocker): let the revive flow be testable.
		window.setTimeout(function () {
			push({ t: "ad", kind: "reward", granted: true, simulated: true });
		}, 300);
	}

	function init() {
		if (initialised) return;
		initialised = true;
		if (!window.y8 || !window.y8.sdk || !APP_ID) {
			push({ t: "ready" });
			push({ t: "auth", name: "Guest" });
			return;
		}
		sdk = window.y8.sdk();
		sdk.init(
			{ appId: APP_ID, autoLogin: true },
			{
				gameId: GAME_ID,
				preloadAdBreaks: "auto",
				sound: "on",
				onReady: function () {
					adsOk = true;
					push({ t: "ready" });
				}
			}
		);
		sdk.onAuth(function (user, error) {
			push({ t: "auth", name: !error && user && user.nickname ? user.nickname : "Guest" });
		});
		if (!adsOk) push({ t: "ready" });
	}

	// Every ad path must produce exactly one ad event, or the game waits forever.
	function finishAd(kind, granted) {
		if (adInFlight) {
			adInFlight = false;
			push({ t: "ad", kind: kind, granted: !!granted });
		}
	}

	function showAd(kind) {
		if (adInFlight) return;
		if (!sdk || !adsOk) {
			if (kind === "reward") fakeReward();
			return;
		}
		adInFlight = true;
		var grantedFlag = false;
		var killer = window.setTimeout(function () {
			finishAd(kind, kind === "reward");
		}, AD_TIMEOUT_MS);
		var base = {
			name: kind === "reward" ? "revive" : "start-game",
			beforeAd: function () {},
			afterAd: function () {
				window.clearTimeout(killer);
				finishAd(kind, false);
			},
			adBreakDone: function () {
				window.clearTimeout(killer);
				finishAd(kind, kind === "reward" ? grantedFlag : false);
			}
		};
		var opts = Object.assign({}, base, { type: kind });
		if (kind === "reward") {
			opts.beforeReward = function (showAdFn) {
				showAdFn();
			};
			opts.adViewed = function () {
				grantedFlag = true;
			};
			opts.adDismissed = function () {
				grantedFlag = false;
			};
		}
		sdk.showAd(opts).catch(function (e) {
			window.clearTimeout(killer);
			console.warn("y8 ad failed", e);
			finishAd(kind, kind === "reward");
		});
	}

	window.DvDY8 = {
		boot: function () {
			init();
			return "ok";
		},
		started: function () {
			return "ok";
		},
		ad: function (kind) {
			showAd(kind === "reward" ? "reward" : "start");
			return "ok";
		},
		score: function (points) {
			if (!sdk) return "skip";
			sdk
				.saveLeaderboardScore({
					table: TABLE,
					points: points,
					allowDuplicates: false,
					highest: true
				})
				.then(function () {
					push({ t: "score", ok: true });
				})
				.catch(function (e) {
					console.warn("y8 score failed", e);
					push({ t: "score", ok: false });
				});
			return "ok";
		},
		leaderboard: function () {
			if (!sdk) return "skip";
			sdk.showLeaderboard({ table: TABLE, mode: "alltime", highest: true });
			return "ok";
		},
		save: function (key, value) {
			if (!sdk) return "skip";
			sdk.saveData({ key: key, value: value, retries: true }).catch(function (e) {
				console.warn("y8 save failed", e);
			});
			return "ok";
		},
		load: function (key) {
			if (!sdk) {
				push({ t: "value", key: key, value: "" });
				return "skip";
			}
			sdk
				.loadData({ key: key })
				.then(function (value) {
					push({ t: "value", key: key, value: value || "" });
				})
				.catch(function () {
					push({ t: "value", key: key, value: "" });
				});
			return "ok";
		},
		profile: function () {
			if (sdk) sdk.openProfile();
			return "ok";
		},
		poll: function () {
			if (!events.length) return "";
			var out = JSON.stringify(events);
			events = [];
			return out;
		}
	};

	// The SDK tag is async, so it can land after this script runs.
	window.addEventListener(
		"y8sdk.ready",
		function () {
			init();
		},
		{ once: true }
	);
	if (window.y8 && window.y8.emitReadyEvent) window.y8.emitReadyEvent();
})();
