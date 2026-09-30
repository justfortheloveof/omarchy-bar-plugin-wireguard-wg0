// Pure helpers for WireGuard status, peer parsing and display text. No QML or
// Qt dependencies, so node can unit test them (tests/model.test.cjs).

function asText(value) {
  return value === undefined || value === null ? "" : String(value);
}

// True for a finite number or a non-empty numeric string. Number() alone would
// also accept "", null, booleans and arrays.
function isNum(v) {
  if (typeof v !== "number" && typeof v !== "string") return false;
  if (v === "") return false;
  return isFinite(Number(v));
}

// The one user-facing shape for a failed command: what ran and how it ended.
// `tail` qualifies an exit-0 run whose output could not be read.
function cmdFail(cmd, exitCode, timedOut, tail) {
  var outcome = timedOut ? "timed out" : "exit " + exitCode;
  return "Failed running: `" + asText(cmd) + "` (" + outcome + ")" + (tail ? tail : "");
}

function linkDownMessage(interfaceName) {
  return "Interface `" + (asText(interfaceName) || "wg0") + "` exists but its link is down";
}

// Parse `ip -j addr show dev <if>`. Returns {up, v4, v6}. Throws unless the
// output is exactly one entry for the expected interface with a flags list.
function parseIpAddr(raw, expectedIf) {
  var text = asText(raw).trim();
  if (text === "") throw new Error("ip output is empty");
  var doc = JSON.parse(text);
  if (!Array.isArray(doc)) throw new Error("ip output is not a list");
  if (doc.length !== 1) throw new Error("ip output is not a single interface");
  var entry = doc[0] || {};
  if (asText(expectedIf) !== "" && entry.ifname !== expectedIf) throw new Error("ip output is for another interface");
  if (!Array.isArray(entry.flags)) throw new Error("ip output has no flags");
  var up = false;
  for (var k = 0; k < entry.flags.length; k++) {
    if (String(entry.flags[k]).toUpperCase() === "UP") {
      up = true;
      break;
    }
  }
  var v4 = "";
  var v6 = "";
  var addrs = Array.isArray(entry.addr_info) ? entry.addr_info : [];
  for (var j = 0; j < addrs.length; j++) {
    var a = addrs[j];
    if (!a || typeof a.local !== "string" || a.local === "") continue;
    if (a.family === "inet" && v4 === "") v4 = a.local;
    else if (a.family === "inet6" && v6 === "" && String(a.scope || "").toLowerCase() !== "host") v6 = a.local;
  }
  return { up: up, v4: v4, v6: v6 };
}

// Classify one status poll. Returns {state: "up" | "down" | "error", v4, v6,
// error}. "down" means the interface does not exist, which is what wg-quick
// down leaves behind. An interface that exists without the UP flag is an
// error: wg-quick cannot bring it up, so the toggle must not offer to. The
// spawn runs under LC_ALL=C, so the English stderr match is reliable.
function statusState(stdout, errText, exitCode, expectedIf, cmd) {
  if (exitCode === 0) {
    var parsed;
    try {
      parsed = parseIpAddr(stdout, expectedIf);
    } catch (e) {
      return {
        state: "error",
        v4: "",
        v6: "",
        error: cmdFail(cmd, 0, false, ": unreadable output"),
      };
    }
    if (!parsed.up)
      return {
        state: "error",
        v4: "",
        v6: "",
        error: linkDownMessage(expectedIf),
      };
    return { state: "up", v4: parsed.v4, v6: parsed.v6, error: "" };
  }
  var err = asText(errText) + " " + asText(stdout);
  if (/does not exist/i.test(err)) return { state: "down", v4: "", v6: "", error: "" };
  return {
    state: "error",
    v4: "",
    v6: "",
    error: cmdFail(cmd, exitCode, false),
  };
}

// First 6 and last 6 characters of a public key.
function shortKey(key) {
  var s = asText(key).trim();
  return s.length > 12 ? s.substring(0, 6) + "…" + s.substring(s.length - 6) : s;
}

// Binary units up to GB: "512 B", "1.5 KB", "3.2 MB", "1.25 GB".
function humanBytes(bytes) {
  var n = Number(bytes);
  if (!isFinite(n) || n < 0) n = 0;
  if (n < 1024) return Math.round(n) + " B";
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB";
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " MB";
  return (n / (1024 * 1024 * 1024)).toFixed(2) + " GB";
}

// Whole seconds as "1d 12h 1m 3s", largest unit first, zero parts dropped.
function compactDuration(seconds) {
  var total = Math.max(0, Math.floor(Number(seconds) || 0));
  var parts = [];
  var units = [
    ["d", 86400],
    ["h", 3600],
    ["m", 60],
    ["s", 1],
  ];
  for (var i = 0; i < units.length; i++) {
    var count = Math.floor(total / units[i][1]);
    if (count <= 0) continue;
    parts.push(count + units[i][0]);
    total -= count * units[i][1];
  }
  return parts.length > 0 ? parts.join(" ") : "0s";
}

// Age of a unix-seconds handshake timestamp; 0 means no handshake yet.
function handshakeAgo(epoch, nowMs) {
  var e = Number(epoch);
  if (!isFinite(e) || e <= 0) return "never";
  return compactDuration(Math.round((Number(nowMs) || Date.now()) / 1000 - e));
}

var HANDSHAKE_STALE_DEFAULT_SEC = 145;

// Filled shield while up, outlined otherwise (U+F0D33 / U+F0D34). Shared by the
// bar, the panel and notifications.
var GLYPH_UP = "󰴳";
var GLYPH_DOWN = "󰴴";

// A handshake older than `thresholdSec` (default HANDSHAKE_STALE_DEFAULT_SEC),
// or one that never completed. A missing reading is not stale; it renders as
// "--". A never-completed handshake is stale only once the tunnel has been up
// (since `upSinceMs`) for longer than the threshold: right after an up, no
// peer has had the chance to shake hands yet. Without `upSinceMs` it is
// stale at once.
function isHandshakeStale(epoch, nowMs, thresholdSec, upSinceMs) {
  if (!isNum(epoch)) return false;
  var n = Number(epoch);
  var now = Number(nowMs) || Date.now();
  var limit = isNum(thresholdSec) ? Number(thresholdSec) : HANDSHAKE_STALE_DEFAULT_SEC;
  if (n <= 0) {
    if (!isNum(upSinceMs) || Number(upSinceMs) <= 0) return true;
    return (now - Number(upSinceMs)) / 1000 > limit;
  }
  return Math.max(0, Math.round(now / 1000 - n)) > limit;
}

// Settings --------------------------------------------------------------------

// Stored inline on the widget's bar entry in shell.json. Keep in sync with
// manifest.json barWidget.defaults.
var HANDSHAKE_MIN_SEC = 120;
var HANDSHAKE_MAX_SEC = 86400;
var POLL_MIN_SEC = 1;
var POLL_MAX_SEC = 3600;
var POLL_DEFAULT_SEC = 10;
var PREF_DEFAULTS = {
  notifyExternalDrop: true,
  handshakeError: true,
  handshakeStaleAfterSec: HANDSHAKE_STALE_DEFAULT_SEC,
  pollIntervalSec: POLL_DEFAULT_SEC,
};

// `omarchy bar set` stores strings, so "true"/"false"/"1"/"0" count too.
function boolPref(value, fallback) {
  if (typeof value === "boolean") return value;
  if (value === 1 || value === 0) return value === 1;
  if (typeof value === "string") {
    var s = value.trim().toLowerCase();
    if (s === "true" || s === "1" || s === "on" || s === "yes") return true;
    if (s === "false" || s === "0" || s === "off" || s === "no") return false;
  }
  return fallback;
}

// Whole numbers only; out-of-range values are clamped, anything else falls back.
function intPref(value, fallback, min, max) {
  if (!isNum(value)) return fallback;
  var n = Number(value);
  if (Math.floor(n) !== n) return fallback;
  return Math.max(min, Math.min(max, n));
}

// The shell's `settings` object (or anything else) -> a complete, valid prefs
// record. Unknown keys are dropped.
function normalizePrefs(raw) {
  var r = raw !== null && typeof raw === "object" ? raw : {};
  return {
    notifyExternalDrop: boolPref(r.notifyExternalDrop, PREF_DEFAULTS.notifyExternalDrop),
    handshakeError: boolPref(r.handshakeError, PREF_DEFAULTS.handshakeError),
    handshakeStaleAfterSec: intPref(
      r.handshakeStaleAfterSec,
      PREF_DEFAULTS.handshakeStaleAfterSec,
      HANDSHAKE_MIN_SEC,
      HANDSHAKE_MAX_SEC,
    ),
    pollIntervalSec: intPref(r.pollIntervalSec, PREF_DEFAULTS.pollIntervalSec, POLL_MIN_SEC, POLL_MAX_SEC),
  };
}

function samePrefs(a, b) {
  a = normalizePrefs(a);
  b = normalizePrefs(b);
  return (
    a.notifyExternalDrop === b.notifyExternalDrop &&
    a.handshakeError === b.handshakeError &&
    a.handshakeStaleAfterSec === b.handshakeStaleAfterSec &&
    a.pollIntervalSec === b.pollIntervalSec
  );
}

// Copies of `peers` with handshakeStale recomputed from each record's raw
// handshakeEpoch, for a threshold change between polls. `upSinceMs` as in
// isHandshakeStale.
function restalePeers(peers, nowMs, thresholdSec, upSinceMs) {
  var list = Array.isArray(peers) ? peers : [];
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var rec = {};
    for (var k in list[i]) rec[k] = list[i][k];
    rec.handshakeStale =
      rec.handshakeEpoch !== null &&
      rec.handshakeEpoch !== undefined &&
      isHandshakeStale(rec.handshakeEpoch, nowMs, thresholdSec, upSinceMs);
    out.push(rec);
  }
  return out;
}

function stalePeerKeys(peers) {
  var list = Array.isArray(peers) ? peers : [];
  var keys = [];
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].handshakeStale) keys.push(asText(list[i].shortKey));
  return keys;
}

// Card and toast text for stale handshakes. It names the peers and the
// threshold but not the age, so it stays put from one poll to the next.
function handshakeErrorMessage(staleShortKeys, thresholdSec) {
  var keys = Array.isArray(staleShortKeys) ? staleShortKeys : [];
  if (keys.length === 0) return "";
  var limit = compactDuration(isNum(thresholdSec) ? thresholdSec : HANDSHAKE_STALE_DEFAULT_SEC);
  if (keys.length === 1) return "Peer " + keys[0] + " has had no handshake for over " + limit;
  return keys.length + " peers have had no handshake for over " + limit;
}

function keepaliveText(seconds) {
  var n = Number(seconds);
  if (!isFinite(n) || n <= 0) return "off";
  return "every " + compactDuration(n);
}

// The peer queries, one non-secret `wg show wg0 <arg>` field each, so no
// output ever carries a private or preshared key. `table` is the number of
// value columns per row (0 = bare key list).
var PEER_CHAIN = [
  { field: "peerList", arg: "peers", table: 0 },
  { field: "endpoints", arg: "endpoints", table: 1 },
  { field: "allowedIps", arg: "allowed-ips", table: 1 },
  { field: "handshakes", arg: "latest-handshakes", table: 1 },
  { field: "transfer", arg: "transfer", table: 2 },
  { field: "keepalives", arg: "persistent-keepalive", table: 1 },
];

function peerChain() {
  return PEER_CHAIN.slice();
}

// `wg show wg0 peers`: one public key per line, blank lines skipped.
function parsePeerList(raw) {
  var keys = [];
  var lines = asText(raw).split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (line === "") continue;
    if (/\s/.test(line)) throw new Error("wg peers line is not a bare public key");
    keys.push(line);
  }
  return keys;
}

// `wg show wg0 <field>`: `<pubkey>\t<value>...` per line. Returns [{key, fields}].
// Throws on a row with the wrong number of columns.
function parsePeerTable(raw, fieldCount) {
  var rows = [];
  var lines = asText(raw).split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line.trim() === "") continue;
    var f = line.split("\t");
    if (f.length !== 1 + fieldCount) throw new Error("wg field table line is malformed");
    rows.push({ key: f[0], fields: f.slice(1) });
  }
  return rows;
}

// Store one chain step's parsed output in `doc`. Never throws. Returns
// {failed: true} on a non-zero exit or unparseable output, otherwise {done}
// with done set on the last step.
function handlePeerStep(doc, stepIndex, exitCode, stdout) {
  if (exitCode !== 0) return { failed: true, doc: doc };
  var step = PEER_CHAIN[stepIndex];
  if (!step) return { failed: true, doc: doc };
  var value;
  try {
    value = stepIndex === 0 ? parsePeerList(stdout) : parsePeerTable(stdout, step.table);
  } catch (e) {
    return { failed: true, doc: doc };
  }
  doc[step.field] = value;
  return { done: stepIndex + 1 === PEER_CHAIN.length, doc: doc };
}

// Merge the chain's tables by public key into display records {publicKey,
// shortKey, endpoint, allowedIps, handshake, handshakeEpoch, handshakeStale,
// downloaded, uploaded, keepalive}. Order follows the peer list, then any key
// seen only in a table (a peer added between queries). wg's own sentinels
// ("(none)", "off") pass through; a peer missing from a table shows "--".
// `staleAfterSec` defaults to HANDSHAKE_STALE_DEFAULT_SEC; `upSinceMs` as in
// isHandshakeStale.
function buildPeers(doc, nowMs, staleAfterSec, upSinceMs) {
  doc = doc || {};
  var tables = ["endpoints", "allowedIps", "handshakes", "transfer", "keepalives"];
  var known = {};
  var order = [];
  function addKey(k) {
    k = String(k);
    if (!Object.prototype.hasOwnProperty.call(known, k)) {
      known[k] = true;
      order.push(k);
    }
  }
  var peerList = Array.isArray(doc.peerList) ? doc.peerList : [];
  for (var i = 0; i < peerList.length; i++) addKey(peerList[i]);

  var byTable = {};
  for (var t = 0; t < tables.length; t++) {
    var rows = Array.isArray(doc[tables[t]]) ? doc[tables[t]] : [];
    var index = {};
    for (var r = 0; r < rows.length; r++) {
      var key = String(rows[r].key);
      addKey(key);
      if (!Object.prototype.hasOwnProperty.call(index, key)) index[key] = rows[r].fields;
    }
    byTable[tables[t]] = index;
  }
  function fieldsOf(table, key) {
    return Object.prototype.hasOwnProperty.call(byTable[table], key) ? byTable[table][key] : null;
  }

  var peers = [];
  for (var p = 0; p < order.length; p++) {
    var pk = order[p];
    var rec = { publicKey: pk, shortKey: shortKey(pk) };

    var f = fieldsOf("endpoints", pk);
    rec.endpoint = f === null ? "--" : f[0];

    f = fieldsOf("allowedIps", pk);
    var cidrs =
      f === null
        ? []
        : asText(f[0])
            .split(/\s+/)
            .filter(function (s) {
              return s !== "";
            });
    rec.allowedIps = cidrs.length === 0 ? "--" : cidrs.join(", ");

    f = fieldsOf("handshakes", pk);
    rec.handshake = f === null ? "--" : isNum(f[0]) ? handshakeAgo(f[0], nowMs) : f[0];
    rec.handshakeEpoch = f === null ? null : f[0];
    rec.handshakeStale = f !== null && isHandshakeStale(f[0], nowMs, staleAfterSec, upSinceMs);

    f = fieldsOf("transfer", pk);
    rec.downloaded = f === null ? "--" : isNum(f[0]) ? humanBytes(f[0]) : f[0];
    rec.uploaded = f === null ? "--" : isNum(f[1]) ? humanBytes(f[1]) : f[1];

    f = fieldsOf("keepalives", pk);
    rec.keepalive = f === null ? "--" : isNum(f[0]) ? keepaliveText(f[0]) : f[0];

    peers.push(rec);
  }
  return peers;
}

// Classify a poll that reported `nextState`. Only a down that follows an up
// this instance saw, with no plugin down pending and no drop already latched,
// is "external". A pending plugin down makes it "expected". With
// `reportExternal` false (the notifyExternalDrop setting) an external drop is
// "ignored": consumed like one, but not latched or reported.
function classifyDrop(nextState, sawUp, latched, selfInitiatedDown, reportExternal) {
  if (nextState !== "down") return "none";
  if (latched) return "none";
  if (selfInitiatedDown) return "expected";
  if (!sawUp) return "none";
  return reportExternal === false ? "ignored" : "external";
}

// Panel copy for an outside drop. The toast (below) is shorter because the
// notification card elides its body after three lines.
function externalDropMessage(interfaceName) {
  var name = asText(interfaceName) || "wg0";
  return (
    "The " +
    name +
    " tunnel was brought down unexpectedly (outside of this plugin). Your traffic is no longer being tunnelled."
  );
}

// The toast card draws no button, so a clickable toast says so in its text.
// `canRestore` is false when no click action could be attached.
function externalDropToast(interfaceName, canRestore) {
  var what = "The " + (asText(interfaceName) || "wg0") + " tunnel was brought down unexpectedly";
  return canRestore ? what + "! Click to bring it back up." : what + ".";
}

function statusRow(state, busy, desired, droppedExternally) {
  if (busy && desired !== "") return desired === "up" ? "Bringing up…" : "Bringing down…";
  if (droppedExternally) return "Error";
  if (state === "up") return "Up";
  if (state === "down") return "Down";
  if (state === "error") return "Error";
  return "Checking…";
}

// Panel hero subtitle. Only a confirmed state makes a claim about traffic.
function heroMeta(state) {
  if (state === "up") return "ENCRYPTING AND ENCAPSULATING";
  if (state === "down") return "FULLY EXPOSED";
  if (state === "error") return "STATUS UNKNOWN";
  return "CHECKING";
}

// Toggling is allowed only from a confirmed up/down with nothing in flight.
function canToggle(state, busy) {
  return !busy && (state === "up" || state === "down");
}

// A failed action's error is stale once a poll confirms the state it was
// after (the user fixed it by hand, or the command half-worked).
function actionTargetReached(failedDirection, state) {
  return (failedDirection === "up" || failedDirection === "down") && failedDirection === state;
}

// Highest-priority error for the panel's single error card:
// action > status > peer > handshake.
function derivedLastError(channels) {
  channels = channels || {};
  return (
    asText(channels.actionError) ||
    asText(channels.statusError) ||
    asText(channels.peerError) ||
    asText(channels.handshakeError)
  );
}

// IPv4 if present, else IPv6, else "--".
function ipDisplay(v4, v6) {
  return asText(v4) || asText(v6) || "--";
}

// Decide whether a stashed peer-chain failure is reported once the follow-up
// status poll lands. If the tunnel went down, the failure was caused by that
// and is dropped; otherwise (still up, or status unreadable) it is reported.
function classifyPeerFailure(pending, statusResult) {
  if (!pending) return "drop";
  return statusResult && statusResult.state === "down" ? "drop" : "report";
}

// A peer-chain result applies only if nothing bumped the generation since it
// started and the tunnel is still up.
function peerApplyAllowed(gen, currentGen, state) {
  return gen === currentGen && state === "up";
}

function peerStartAllowed(state, actionBusy) {
  return state === "up" && !actionBusy;
}
