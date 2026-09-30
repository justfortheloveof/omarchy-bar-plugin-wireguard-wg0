// Unit tests for Model.js - run with: node --test tests/model.test.cjs
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const vm = require("node:vm");

const ctx = vm.createContext({});
vm.runInContext(fs.readFileSync(`${__dirname}/../Model.js`, "utf8"), ctx);

const IP_UP = JSON.stringify([
  {
    ifindex: 7,
    ifname: "wg0",
    flags: ["UP", "LOWER_UP"],
    addr_info: [
      { family: "inet", local: "10.66.0.2", prefixlen: 32, scope: "host" },
      { family: "inet6", local: "fe80::1", prefixlen: 64, scope: "link" },
    ],
  },
]);

// Display forms of the commands Service.qml runs.
const IP_CMD = "/usr/bin/ip -j addr show dev wg0";
const QUICK_UP = "sudo -n /usr/bin/wg-quick up wg0";
const QUICK_DOWN = "sudo -n /usr/bin/wg-quick down wg0";
const wgCmd = (arg) => `sudo -n /usr/bin/wg show wg0 ${arg}`;

// Synthetic peer keys and a fixed clock.
const NOW_MS = 1789966547000;
const PK_A = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
const PK_B = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
const PK_X = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=";

test("parseIpAddr extracts the first v4 and first non-host-scope v6", () => {
  const r = ctx.parseIpAddr(IP_UP, "wg0");
  assert.equal(r.v4, "10.66.0.2");
  assert.equal(r.v6, "fe80::1");
});

test("parseIpAddr accepts an up entry with no addresses", () => {
  const noAddrs = JSON.stringify([{ ifname: "wg0", flags: ["UP", "LOWER_UP"] }]);
  const r = ctx.parseIpAddr(noAddrs, "wg0");
  assert.equal(r.v4, "");
  assert.equal(r.v6, "");
});

test("parseIpAddr reports a missing UP flag instead of throwing", () => {
  const down = JSON.stringify([{ ifname: "wg0", flags: ["BROADCAST", "MULTICAST"], addr_info: [] }]);
  assert.equal(ctx.parseIpAddr(down, "wg0").up, false);
  assert.equal(ctx.parseIpAddr(IP_UP, "wg0").up, true);
});

test("parseIpAddr throws on empty, wrong-name, flagless, or multi-entry output", () => {
  assert.throws(() => ctx.parseIpAddr("[]", "wg0"));
  assert.throws(() => ctx.parseIpAddr("", "wg0"));
  assert.throws(() => ctx.parseIpAddr("   ", "wg0"));
  const wrongName = JSON.stringify([{ ifname: "eth0", flags: ["UP", "LOWER_UP"], addr_info: [] }]);
  assert.throws(() => ctx.parseIpAddr(wrongName, "wg0"));
  const noFlags = JSON.stringify([{ ifname: "wg0", addr_info: [] }]);
  assert.throws(() => ctx.parseIpAddr(noFlags, "wg0"));
  const two = JSON.stringify([
    { ifname: "wg0", flags: ["UP"], addr_info: [] },
    { ifname: "wg0", flags: ["UP"], addr_info: [] },
  ]);
  assert.throws(() => ctx.parseIpAddr(two, "wg0"));
});

test("parseIpAddr throws on malformed ip -j output", () => {
  assert.throws(() => ctx.parseIpAddr("not json", "wg0"));
  assert.throws(() => ctx.parseIpAddr('{"ifname":"wg0"}', "wg0")); // not a list
  assert.throws(() => ctx.parseIpAddr("[", "wg0")); // truncated
});

test("statusState: exit 0 with an address is up", () => {
  const r = ctx.statusState(IP_UP, "", 0, "wg0", IP_CMD);
  assert.equal(r.state, "up");
  assert.equal(r.v4, "10.66.0.2");
  assert.equal(r.error, "");
});

test('statusState: "does not exist" on stderr is down, never error', () => {
  const r = ctx.statusState("", 'Device "wg0" does not exist.\n', 1, "wg0", IP_CMD);
  assert.equal(r.state, "down");
  assert.equal(r.error, "");
});

test("statusState: any non-zero exit is an error naming the command and the code", () => {
  // 127 (missing binary) is not special-cased.
  for (const code of [1, 2, 127, 255]) {
    const r = ctx.statusState("", "ip: some failure", code, "wg0", IP_CMD);
    assert.equal(r.state, "error");
    assert.equal(r.error, `Failed running: \`${IP_CMD}\` (exit ${code})`);
    assert.equal(r.v4, "");
    assert.equal(r.v6, "");
  }
});

test("statusState: exit 0 with unreadable output is an error, and says so", () => {
  const r = ctx.statusState("definitely not json", "", 0, "wg0", IP_CMD);
  assert.equal(r.state, "error");
  assert.equal(r.error, `Failed running: \`${IP_CMD}\` (exit 0): unreadable output`);
});

test("statusState: exit 0 with empty, wrong-name, or down output is error, never up or down", () => {
  for (const out of ["[]", "", "   "]) {
    const r = ctx.statusState(out, "", 0, "wg0", IP_CMD);
    assert.equal(r.state, "error");
  }
  const wrongName = JSON.stringify([{ ifname: "eth0", flags: ["UP", "LOWER_UP"], addr_info: [] }]);
  assert.equal(ctx.statusState(wrongName, "", 0, "wg0", IP_CMD).state, "error");
  const down = JSON.stringify([{ ifname: "wg0", flags: ["BROADCAST", "MULTICAST"], addr_info: [] }]);
  const rDown = ctx.statusState(down, "", 0, "wg0", IP_CMD);
  assert.equal(rDown.state, "error");
  assert.equal(rDown.error, "Interface `wg0` exists but its link is down");
});

test("cmdFail: quotes the command and the exit code, and nothing else", () => {
  assert.equal(ctx.cmdFail(QUICK_UP, 1, false), `Failed running: \`${QUICK_UP}\` (exit 1)`);
  assert.notEqual(ctx.cmdFail(QUICK_UP, 1, false), ctx.cmdFail(QUICK_DOWN, 1, false));
  // no advice, no stderr
  assert.doesNotMatch(ctx.cmdFail(QUICK_UP, 1, false), /sudoers|terminal|refresh|NOPASSWD/i);
});

test("cmdFail: a timeout reports no exit code", () => {
  assert.equal(ctx.cmdFail(IP_CMD, 0, true), `Failed running: \`${IP_CMD}\` (timed out)`);
  assert.equal(ctx.cmdFail(IP_CMD, 1, true), `Failed running: \`${IP_CMD}\` (timed out)`);
});

test("cmdFail: the tail carries the one qualifier that has no slot of its own", () => {
  assert.equal(
    ctx.cmdFail(wgCmd("transfer"), 0, false, ": unreadable output"),
    `Failed running: \`${wgCmd("transfer")}\` (exit 0): unreadable output`,
  );
  assert.equal(ctx.cmdFail(IP_CMD, 1, false, ""), `Failed running: \`${IP_CMD}\` (exit 1)`);
  assert.equal(ctx.cmdFail(IP_CMD, 1, false), `Failed running: \`${IP_CMD}\` (exit 1)`);
});

// The notification card elides its body after three lines (~145 chars at the
// default font size). 100 leaves a line of slack.
const TOAST_BUDGET = 100;

function longestPeerCmd() {
  return ctx.peerChain().reduce((a, s) => (wgCmd(s.arg).length > wgCmd(a).length ? s.arg : a), ctx.peerChain()[0].arg);
}

test("every message that reaches a toast fits the shell elision budget", () => {
  const toasts = [
    ctx.cmdFail(wgCmd(longestPeerCmd()), 1, false),
    ctx.cmdFail(wgCmd(longestPeerCmd()), 0, true),
    ctx.cmdFail(wgCmd(longestPeerCmd()), 0, false, ": unreadable output"),
    ctx.cmdFail(QUICK_UP, 1, false),
    ctx.cmdFail(QUICK_UP, 0, true),
    ctx.cmdFail(IP_CMD, 1, false),
    ctx.cmdFail(IP_CMD, 0, false, ": unreadable output"),
    ctx.cmdFail(IP_CMD, 0, true),
    ctx.externalDropToast("wg0", true),
    ctx.externalDropToast("wg0", false),
  ];
  for (const t of toasts) {
    assert.ok(t.length <= TOAST_BUDGET, `${t.length} chars, over budget: ${t}`);
  }
});

test("statusState: every error it can return fits the toast budget", () => {
  const errs = [
    ctx.statusState("junk", "", 0, "wg0", IP_CMD).error,
    ctx.statusState("", "boom", 1, "wg0", IP_CMD).error,
    ctx.statusState("", "", 127, "wg0", IP_CMD).error,
    ctx.linkDownMessage("wg0"),
  ];
  for (const e of errs) {
    assert.ok(e.length > 0);
    assert.ok(e.length <= TOAST_BUDGET, `${e.length} chars, over budget: ${e}`);
  }
});

test("statusRow covers every state plus the in-flight toggle", () => {
  assert.equal(ctx.statusRow("checking", false, ""), "Checking…");
  assert.equal(ctx.statusRow("up", false, ""), "Up");
  assert.equal(ctx.statusRow("down", false, ""), "Down");
  assert.equal(ctx.statusRow("error", false, ""), "Error");
  assert.equal(ctx.statusRow("up", true, "down"), "Bringing down…");
  assert.equal(ctx.statusRow("up", true, "up"), "Bringing up…");
  assert.equal(ctx.statusRow("up", true, ""), "Up"); // not in flight
});

test("statusRow: a latched outside drop reads as an error, the toggle text still wins", () => {
  assert.equal(ctx.statusRow("down", false, "", true), "Error");
  assert.equal(ctx.statusRow("down", false, "", false), "Down");
  assert.equal(ctx.statusRow("up", true, "up", true), "Bringing up…");
  assert.equal(ctx.statusRow("up", false, "", false), "Up");
});

test("heroMeta: only a confirmed state claims anything about traffic", () => {
  assert.equal(ctx.heroMeta("up"), "ENCRYPTING AND ENCAPSULATING");
  assert.equal(ctx.heroMeta("down"), "FULLY EXPOSED");
  assert.equal(ctx.heroMeta("error"), "STATUS UNKNOWN");
  assert.equal(ctx.heroMeta("checking"), "CHECKING");
});

test("classifyDrop: a down is external only if this instance saw the interface up", () => {
  assert.equal(ctx.classifyDrop("down", true, false, false), "external");
  // our own down
  assert.equal(ctx.classifyDrop("down", true, false, true), "expected");
  // never seen up (e.g. right after a restart): not a drop
  assert.equal(ctx.classifyDrop("down", false, false, false), "none");
  // already latched
  assert.equal(ctx.classifyDrop("down", true, true, false), "none");
  // the latch wins over a pending own-down
  assert.equal(ctx.classifyDrop("down", true, true, true), "none");
});

test("classifyDrop: a poll that is not a down never classifies", () => {
  assert.equal(ctx.classifyDrop("up", true, false, false), "none");
  assert.equal(ctx.classifyDrop("error", true, false, false), "none");
  assert.equal(ctx.classifyDrop("checking", true, false, true), "none");
});

// The drop-lane bookkeeping Service.qml does around Model.classifyDrop.
function dropLane() {
  const lane = { sawUp: false, latched: false, expectDown: false };
  lane.arm = () => {
    lane.expectDown = true;
  };
  lane.poll = (state) => {
    if (state === "up") {
      lane.sawUp = true;
      lane.latched = false;
      lane.expectDown = false;
      return "none";
    }
    if (state !== "down") return "none";
    const drop = ctx.classifyDrop(state, lane.sawUp, lane.latched, lane.expectDown);
    lane.expectDown = false;
    if (drop !== "none") lane.sawUp = false;
    if (drop === "external") lane.latched = true;
    return drop;
  };
  return lane;
}

test("classifyDrop over a poll sequence: one report per drop, an arm survives a bad poll", () => {
  const outside = dropLane();
  outside.poll("up");
  // an unreadable poll does not hide the drop
  assert.equal(outside.poll("error"), "none");
  assert.equal(outside.poll("down"), "external");
  // latched: no second report
  assert.equal(outside.poll("down"), "none");
  assert.equal(outside.poll("up"), "none");
  assert.equal(outside.poll("down"), "external");

  const mine = dropLane();
  mine.poll("up");
  mine.arm();
  // an unreadable poll does not consume the pending down
  assert.equal(mine.poll("error"), "none");
  assert.equal(mine.poll("down"), "expected");
});

test("externalDropMessage says what happened and what it costs, not what to do", () => {
  const f = ctx.externalDropMessage("wg0");
  assert.equal(
    f,
    "The wg0 tunnel was brought down unexpectedly (outside of this plugin). Your traffic is no longer being tunnelled.",
  );
  // what happened and what it costs; no instructions
  assert.equal(f.split(". ").length, 2);
  assert.match(f, /^The wg0 tunnel was brought down unexpectedly/);
  assert.doesNotMatch(f, /wg-quick|Turn it back|run sudo/i);
});

test("externalDropMessage names the interface it was asked about", () => {
  const f = ctx.externalDropMessage("wg1");
  assert.match(f, /^The wg1 tunnel was brought down/);
  const d = ctx.externalDropMessage("");
  assert.match(d, /^The wg0 tunnel was brought down/);
});

test("externalDropToast: the actionable copy is what the three lines have to say", () => {
  assert.equal(
    ctx.externalDropToast("wg0", true),
    "The wg0 tunnel was brought down unexpectedly! Click to bring it back up.",
  );
  // no click action attached: no click promised
  assert.equal(ctx.externalDropToast("wg0", false), "The wg0 tunnel was brought down unexpectedly.");
  assert.equal(ctx.externalDropToast("", false), ctx.externalDropToast("wg0", false));
  assert.match(ctx.externalDropToast("", false), /^The wg0 tunnel was brought down unexpectedly/);
});

test("externalDropToast: the toast is shorter than the panel text, which may wrap past the budget", () => {
  const panel = ctx.externalDropMessage("wg0");
  assert.ok(ctx.externalDropToast("wg0", true).length < panel.length);
  assert.ok(ctx.externalDropToast("wg0", false).length < panel.length);
  assert.ok(panel.length > TOAST_BUDGET);
});

test("externalDropToast: only a toast that can be clicked says to click", () => {
  // the card has no button, so the text must say it is clickable
  assert.match(ctx.externalDropToast("wg0", true), /Click to/);
  assert.doesNotMatch(ctx.externalDropToast("wg0", false), /Click/);
  assert.doesNotMatch(ctx.externalDropToast("", false), /Click/);
});

test("shortKey keeps the first and last 6 chars, short keys untouched", () => {
  assert.equal(ctx.shortKey(PK_A), "AAAAAA…AAAAA=");
  assert.equal(ctx.shortKey("short"), "short");
  assert.equal(ctx.shortKey(""), "");
});

test("humanBytes: binary 1024 steps, 1 decimal on KB/MB, 2 on GB, stops at GB", () => {
  assert.equal(ctx.humanBytes(0), "0 B");
  assert.equal(ctx.humanBytes(999), "999 B");
  assert.equal(ctx.humanBytes(1000), "1000 B");
  assert.equal(ctx.humanBytes(1023), "1023 B");
  assert.equal(ctx.humanBytes(1024), "1.0 KB");
  assert.equal(ctx.humanBytes(1536), "1.5 KB");
  assert.equal(ctx.humanBytes(592340), "578.5 KB");
  assert.equal(ctx.humanBytes(2375032), "2.3 MB");
  assert.equal(ctx.humanBytes(1073741824), "1.00 GB");
  // no TB tier
  assert.equal(ctx.humanBytes(1099511627776), "1024.00 GB");
  assert.equal(ctx.humanBytes(-5), "0 B");
  assert.equal(ctx.humanBytes("abc"), "0 B");
});

test("handshakeAgo: compact, largest unit first, zero components dropped", () => {
  const now = NOW_MS;
  const ago = (s) => ctx.handshakeAgo(now / 1000 - s, now);
  assert.equal(ctx.handshakeAgo(0, now), "never");
  assert.equal(ctx.handshakeAgo(-1, now), "never");
  assert.equal(ago(0), "0s");
  assert.equal(ago(1), "1s");
  assert.equal(ago(6), "6s");
  assert.equal(ago(59), "59s");
  assert.equal(ago(60), "1m");
  assert.equal(ago(63), "1m 3s");
  assert.equal(ago(83), "1m 23s");
  assert.equal(ago(121), "2m 1s");
  assert.equal(ago(1800), "30m");
  assert.equal(ago(3599), "59m 59s");
  assert.equal(ago(3600), "1h");
  assert.equal(ago(3661), "1h 1m 1s");
  assert.equal(ago(43263), "12h 1m 3s");
  assert.equal(ago(86400), "1d");
  assert.equal(ago(129663), "1d 12h 1m 3s");
  assert.equal(ago(2 * 86400), "2d");
  // future timestamps clamp to zero
  assert.equal(ctx.handshakeAgo(now / 1000 + 600, now), "0s");
});

test("keepaliveText: off at 0, compact interval above it", () => {
  assert.equal(ctx.keepaliveText(0), "off");
  assert.equal(ctx.keepaliveText(-5), "off");
  assert.equal(ctx.keepaliveText("off"), "off");
  assert.equal(ctx.keepaliveText(""), "off");
  assert.equal(ctx.keepaliveText("abc"), "off");
  assert.equal(ctx.keepaliveText(1), "every 1s");
  assert.equal(ctx.keepaliveText(25), "every 25s");
  assert.equal(ctx.keepaliveText(60), "every 1m");
  assert.equal(ctx.keepaliveText(90), "every 1m 30s");
  assert.equal(ctx.keepaliveText(3600), "every 1h");
  assert.equal(ctx.keepaliveText(43263), "every 12h 1m 3s");
  assert.equal(ctx.keepaliveText(129663), "every 1d 12h 1m 3s");
});

// Runs each chain step through the stub sudo/wg with the argv Service.qml
// builds (minus the env LC_ALL=C prefix).
const STUB_DIR = path.join(__dirname, "stub");

// Returns {exitCode, stdout}; a non-zero exit is captured, not thrown.
function runStubStep(arg, peerState) {
  try {
    const out = execFileSync(path.join(STUB_DIR, "sudo"), ["-n", path.join(STUB_DIR, "wg"), "show", "wg0", arg], {
      env: {
        ...process.env,
        WG_STUB_PEER: peerState,
        PATH: `${STUB_DIR}:${process.env.PATH || ""}`,
      },
    });
    return { exitCode: 0, stdout: out.toString() };
  } catch (e) {
    return { exitCode: e.status, stdout: (e.stdout || "").toString() };
  }
}

test("the stub command chain feeds the six-step peer merge", () => {
  const chain = ctx.peerChain();
  let doc = {};
  for (let i = 0; i < chain.length; i++) {
    const r = runStubStep(chain[i].arg, "one");
    const h = ctx.handlePeerStep(doc, i, r.exitCode, r.stdout);
    assert.equal(h.failed, undefined, `step ${i} (${chain[i].arg}) failed unexpectedly`);
    assert.equal(h.done, i === chain.length - 1);
  }
  // The stub's handshake is relative to its own clock, 58 s back.
  const peers = ctx.buildPeers(doc, Date.now());
  assert.equal(peers.length, 1);
  const p = peers[0];
  assert.equal(p.handshakeStale, false);
  assert.equal(p.publicKey, "ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ=");
  assert.equal(p.shortKey, "ZZZZZZ…ZZZZZ=");
  assert.equal(p.endpoint, "192.0.2.65:52871");
  assert.equal(p.allowedIps, "0.0.0.0/0, ::/0");
  assert.match(p.handshake, /^5[89]s$/);
  assert.equal(p.downloaded, "2.3 MB");
  assert.equal(p.uploaded, "578.5 KB");
  assert.equal(p.keepalive, "every 25s");
});

test("the stale stub peer is an hour old", () => {
  const r = runStubStep("latest-handshakes", "stale");
  const doc = {
    peerList: ["ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ="],
    handshakes: ctx.parsePeerTable(r.stdout, 1),
  };
  const p = ctx.buildPeers(doc, Date.now())[0];
  assert.equal(p.handshakeStale, true);
  assert.match(p.handshake, /^(59m 59s|1h( 1s)?)$/);
});

test("a stub wg that fails surfaces as a failed step", () => {
  const r = runStubStep("peers", "fail");
  assert.equal(r.exitCode, 1);
  const h = ctx.handlePeerStep({}, 0, r.exitCode, r.stdout);
  assert.equal(h.failed, true);
});

test("a stub wg that emits a malformed table surfaces as a failed step", () => {
  const r = runStubStep("transfer", "malformed");
  assert.equal(r.exitCode, 0);
  const h = ctx.handlePeerStep({}, 4, r.exitCode, r.stdout);
  assert.equal(h.failed, true);
});

test("an unknown wg field is rejected by the stub with a non-zero exit", () => {
  const r = runStubStep("dump", "one");
  assert.equal(r.exitCode, 64);
});

// Peer chain: parsers, step driver, merge

test("peerChain returns the six steps in the exact contract order", () => {
  const c = ctx.peerChain();
  assert.equal(c.length, 6);
  // JSON compare: vm-context arrays fail strict prototype checks.
  const expected = [
    { field: "peerList", arg: "peers", table: 0 },
    { field: "endpoints", arg: "endpoints", table: 1 },
    { field: "allowedIps", arg: "allowed-ips", table: 1 },
    { field: "handshakes", arg: "latest-handshakes", table: 1 },
    { field: "transfer", arg: "transfer", table: 2 },
    { field: "keepalives", arg: "persistent-keepalive", table: 1 },
  ];
  assert.equal(JSON.stringify(c), JSON.stringify(expected));
});

test("parsePeerList keeps order, skips blank lines, and rejects non-bare keys", () => {
  assert.equal(JSON.stringify(ctx.parsePeerList(PK_A + "\n" + PK_B + "\n")), JSON.stringify([PK_A, PK_B]));
  assert.equal(JSON.stringify(ctx.parsePeerList("\n" + PK_A + "\n  \n" + PK_B + "\n\n")), JSON.stringify([PK_A, PK_B]));
  assert.equal(JSON.stringify(ctx.parsePeerList("")), "[]");
  assert.throws(() => ctx.parsePeerList(PK_A + "\t1.2.3.4:51820\n"));
  assert.throws(() => ctx.parsePeerList(PK_A + " " + PK_B + "\n"));
});

test("parsePeerTable parses 1-field and 2-field rows and enforces the count", () => {
  const one = ctx.parsePeerTable(PK_A + "\t1.2.3.4:51820\n\n" + PK_B + "\t(none)\n", 1);
  assert.equal(one.length, 2);
  assert.equal(JSON.stringify(one[0]), JSON.stringify({ key: PK_A, fields: ["1.2.3.4:51820"] }));
  assert.equal(JSON.stringify(one[1]), JSON.stringify({ key: PK_B, fields: ["(none)"] }));
  const two = ctx.parsePeerTable(PK_A + "\t2375032\t592340\n", 2);
  assert.equal(JSON.stringify(two), JSON.stringify([{ key: PK_A, fields: ["2375032", "592340"] }]));
  assert.equal(ctx.parsePeerTable("\n\t\n", 1).length, 0);
  assert.throws(() => ctx.parsePeerTable(PK_A + "\t100\t200\n", 1));
  assert.throws(() => ctx.parsePeerTable(PK_A + "\t100\n", 2));
  assert.throws(() => ctx.parsePeerTable(PK_A + "\n", 1));
});

const CHAIN_STDOUT = [
  PK_A + "\n" + PK_B + "\n",
  PK_A + "\t1.2.3.4:51820\n" + PK_B + "\t(none)\n",
  PK_A + "\t0.0.0.0/0 ::/0\n" + PK_B + "\t(none)\n",
  PK_A + "\t1789966489\n" + PK_B + "\t0\n",
  PK_A + "\t2375032\t592340\n" + PK_B + "\t0\t0\n",
  PK_A + "\t25\n" + PK_B + "\toff\n",
];

test("handlePeerStep walks the happy path to done with every doc field populated", () => {
  let doc = {};
  for (let i = 0; i < 6; i++) {
    const r = ctx.handlePeerStep(doc, i, 0, CHAIN_STDOUT[i]);
    assert.equal(r.failed, undefined, "step " + i + " failed unexpectedly");
    assert.equal(r.done, i === 5);
    assert.equal(r.doc, doc);
  }
  assert.equal(JSON.stringify(doc.peerList), JSON.stringify([PK_A, PK_B]));
  assert.equal(doc.endpoints.length, 2);
  assert.equal(doc.allowedIps.length, 2);
  assert.equal(doc.handshakes.length, 2);
  assert.equal(doc.transfer.length, 2);
  assert.equal(doc.keepalives.length, 2);
});

test("handlePeerStep: a non-zero exit fails without mutating the doc", () => {
  let doc = {};
  let r = ctx.handlePeerStep(doc, 0, 0, PK_A + "\n");
  assert.ok(!r.failed);
  assert.equal(r.done, false);
  const before = Object.keys(doc);
  r = ctx.handlePeerStep(doc, 1, 1, "");
  assert.equal(r.failed, true);
  assert.equal(r.doc, doc);
  assert.deepEqual(Object.keys(doc), before);
  assert.equal(doc.endpoints, undefined);
});

test("handlePeerStep: malformed table stdout fails without mutating the doc", () => {
  let doc = {};
  assert.equal(ctx.handlePeerStep(doc, 0, 0, PK_A + "\n").failed, undefined);
  const before = Object.keys(doc);
  const r = ctx.handlePeerStep(doc, 1, 0, PK_A + "\n1.2.3.4:51820\n"); // key without its tab-separated field
  assert.equal(r.failed, true);
  assert.equal(r.doc, doc);
  assert.deepEqual(Object.keys(doc), before);
  assert.equal(JSON.stringify(doc.peerList), JSON.stringify([PK_A]));
  assert.equal(doc.endpoints, undefined);
});

function onePeerDoc() {
  return {
    peerList: [PK_A],
    endpoints: [{ key: PK_A, fields: ["1.2.3.4:51820"] }],
    allowedIps: [{ key: PK_A, fields: ["0.0.0.0/0 ::/0"] }],
    handshakes: [{ key: PK_A, fields: ["1789966489"] }],
    transfer: [{ key: PK_A, fields: ["2375032", "592340"] }],
    keepalives: [{ key: PK_A, fields: ["25"] }],
  };
}

test("buildPeers formats a fully populated peer", () => {
  const peers = ctx.buildPeers(onePeerDoc(), NOW_MS);
  assert.equal(peers.length, 1);
  const p = peers[0];
  assert.equal(p.publicKey, PK_A);
  assert.equal(p.shortKey, "AAAAAA…AAAAA=");
  assert.equal(p.endpoint, "1.2.3.4:51820");
  assert.equal(p.allowedIps, "0.0.0.0/0, ::/0");
  assert.match(p.handshake, /^5[89]s$/);
  assert.equal(p.downloaded, "2.3 MB");
  assert.equal(p.uploaded, "578.5 KB");
  assert.equal(p.keepalive, "every 25s");
});

test("buildPeers shows sentinel strings as-is and numeric zeros via the helpers", () => {
  const doc = {
    peerList: [PK_A],
    endpoints: [{ key: PK_A, fields: ["(none)"] }],
    allowedIps: [{ key: PK_A, fields: ["(none)"] }],
    handshakes: [{ key: PK_A, fields: ["0"] }],
    transfer: [{ key: PK_A, fields: ["0", "0"] }],
    keepalives: [{ key: PK_A, fields: ["off"] }],
  };
  const p = ctx.buildPeers(doc, NOW_MS)[0];
  assert.equal(p.endpoint, "(none)");
  assert.equal(p.allowedIps, "(none)");
  assert.equal(p.handshake, "never");
  assert.equal(p.downloaded, "0 B");
  assert.equal(p.uploaded, "0 B");
  assert.equal(p.keepalive, "off");
});

// An allowed-ips row with no CIDRs reads "--".
test("buildPeers: an allowed-ips row with no CIDRs reads --, not a synthesized (none)", () => {
  const doc = {
    peerList: [PK_A],
    endpoints: [],
    allowedIps: [{ key: PK_A, fields: ["   "] }],
    handshakes: [],
    transfer: [],
    keepalives: [],
  };
  assert.equal(ctx.buildPeers(doc, NOW_MS)[0].allowedIps, "--");
});

test("buildPeers passes a non-numeric transfer sentinel through, not 0 B", () => {
  const doc = {
    peerList: [PK_A],
    endpoints: [],
    allowedIps: [],
    handshakes: [],
    transfer: [{ key: PK_A, fields: ["(none)", "(none)"] }],
    keepalives: [],
  };
  const p = ctx.buildPeers(doc, NOW_MS)[0];
  assert.equal(p.downloaded, "(none)");
  assert.equal(p.uploaded, "(none)");
});

test("buildPeers shows -- for a peer that is absent from every table", () => {
  const doc = {
    peerList: [PK_A],
    endpoints: [],
    allowedIps: [],
    handshakes: [],
    transfer: [],
    keepalives: [],
  };
  const p = ctx.buildPeers(doc, NOW_MS)[0];
  assert.equal(p.publicKey, PK_A);
  assert.equal(p.endpoint, "--");
  assert.equal(p.allowedIps, "--");
  assert.equal(p.handshake, "--");
  assert.equal(p.downloaded, "--");
  assert.equal(p.uploaded, "--");
  assert.equal(p.keepalive, "--");
});

test("buildPeers shows -- only for the tables a peer is missing from", () => {
  const doc = {
    peerList: [PK_A],
    endpoints: [{ key: PK_A, fields: ["5.6.7.8:51820"] }],
    allowedIps: [],
    handshakes: [],
    transfer: [{ key: PK_A, fields: ["1024", "0"] }],
    keepalives: [],
  };
  const p = ctx.buildPeers(doc, NOW_MS)[0];
  assert.equal(p.endpoint, "5.6.7.8:51820");
  assert.equal(p.allowedIps, "--");
  assert.equal(p.handshake, "--");
  assert.equal(p.downloaded, "1.0 KB");
  assert.equal(p.uploaded, "0 B");
  assert.equal(p.keepalive, "--");
});

test("buildPeers keeps peerList order for multiple peers", () => {
  const doc = {
    peerList: [PK_B, PK_A],
    endpoints: [
      { key: PK_A, fields: ["1.1.1.1:1"] },
      { key: PK_B, fields: ["2.2.2.2:2"] },
    ],
    allowedIps: [
      { key: PK_A, fields: ["10.0.0.0/24"] },
      { key: PK_B, fields: ["(none)"] },
    ],
    handshakes: [
      { key: PK_A, fields: ["1789966489"] },
      { key: PK_B, fields: ["0"] },
    ],
    transfer: [
      { key: PK_A, fields: ["1000", "2000"] },
      { key: PK_B, fields: ["0", "0"] },
    ],
    keepalives: [
      { key: PK_A, fields: ["25"] },
      { key: PK_B, fields: ["off"] },
    ],
  };
  const peers = ctx.buildPeers(doc, NOW_MS);
  assert.equal(peers.length, 2);
  assert.equal(peers[0].publicKey, PK_B);
  assert.equal(peers[1].publicKey, PK_A);
  assert.equal(peers[0].endpoint, "2.2.2.2:2");
  assert.equal(peers[1].endpoint, "1.1.1.1:1");
});

test("buildPeers appends table-only keys after the listed peers in first-seen order", () => {
  const doc = {
    peerList: [PK_A],
    endpoints: [{ key: PK_X, fields: ["3.3.3.3:3"] }],
    allowedIps: [],
    handshakes: [],
    transfer: [{ key: PK_X, fields: ["10", "20"] }],
    keepalives: [{ key: PK_X, fields: ["off"] }],
  };
  const peers = ctx.buildPeers(doc, NOW_MS);
  assert.equal(peers.length, 2);
  assert.equal(peers[0].publicKey, PK_A);
  assert.equal(peers[1].publicKey, PK_X);
  assert.equal(peers[1].endpoint, "3.3.3.3:3");
  assert.equal(peers[1].allowedIps, "--");
  assert.equal(peers[1].handshake, "--");
  assert.equal(peers[1].downloaded, "10 B");
  assert.equal(peers[1].uploaded, "20 B");
  assert.equal(peers[1].keepalive, "off");
  // PK_A is listed but absent from every table
  assert.equal(peers[0].endpoint, "--");
  assert.equal(peers[0].keepalive, "--");
});

test("buildPeers: an empty peer list with empty tables yields an empty list", () => {
  const doc = {
    peerList: [],
    endpoints: [],
    allowedIps: [],
    handshakes: [],
    transfer: [],
    keepalives: [],
  };
  assert.equal(ctx.buildPeers(doc, NOW_MS).length, 0);
});

test("canToggle: only confirmed up/down and not busy", () => {
  assert.equal(ctx.canToggle("up", false), true);
  assert.equal(ctx.canToggle("down", false), true);
  assert.equal(ctx.canToggle("up", true), false);
  assert.equal(ctx.canToggle("down", true), false);
  assert.equal(ctx.canToggle("checking", false), false);
  assert.equal(ctx.canToggle("error", false), false);
  assert.equal(ctx.canToggle("error", true), false);
});

test("actionTargetReached: only the state the failed action was after", () => {
  assert.equal(ctx.actionTargetReached("up", "up"), true);
  assert.equal(ctx.actionTargetReached("down", "down"), true);
  assert.equal(ctx.actionTargetReached("up", "down"), false);
  assert.equal(ctx.actionTargetReached("down", "up"), false);
  assert.equal(ctx.actionTargetReached("down", "error"), false);
  assert.equal(ctx.actionTargetReached("", ""), false);
  assert.equal(ctx.actionTargetReached("", "up"), false);
});

test("derivedLastError: action beats status beats peer, empty is unset", () => {
  const a = "action failed";
  const s = "status failed";
  const p = "peer failed";
  assert.equal(ctx.derivedLastError({ actionError: a, statusError: s, peerError: p }), a);
  assert.equal(ctx.derivedLastError({ actionError: "", statusError: s, peerError: p }), s);
  assert.equal(ctx.derivedLastError({ actionError: "", statusError: "", peerError: p }), p);
  assert.equal(ctx.derivedLastError({ actionError: "", statusError: "", peerError: "" }), "");
  assert.equal(ctx.derivedLastError({}), "");
  assert.equal(ctx.derivedLastError(undefined), "");
  assert.equal(ctx.derivedLastError({ actionError: a }), a);
  assert.equal(ctx.derivedLastError({ statusError: s }), s);
});

test("classifyPeerFailure: status result decides report vs drop", () => {
  assert.equal(ctx.classifyPeerFailure("stashed", { state: "up" }), "report");
  assert.equal(ctx.classifyPeerFailure("stashed", { state: "down" }), "drop");
  assert.equal(ctx.classifyPeerFailure("stashed", { state: "error" }), "report");
  assert.equal(ctx.classifyPeerFailure(null, { state: "up" }), "drop");
  assert.equal(ctx.classifyPeerFailure("", { state: "up" }), "drop");
});

test("peerApplyAllowed: generation must match and state must still be up", () => {
  assert.equal(ctx.peerApplyAllowed(1, 1, "up"), true);
  assert.equal(ctx.peerApplyAllowed(1, 2, "up"), false);
  assert.equal(ctx.peerApplyAllowed(1, 1, "down"), false);
  assert.equal(ctx.peerApplyAllowed(1, 1, "error"), false);
});

test("peerStartAllowed: state up and no action in flight", () => {
  assert.equal(ctx.peerStartAllowed("up", false), true);
  assert.equal(ctx.peerStartAllowed("up", true), false);
  assert.equal(ctx.peerStartAllowed("down", false), false);
  assert.equal(ctx.peerStartAllowed("error", false), false);
});

test("isHandshakeStale: older than 135s or never is stale, absent is not", () => {
  const now = NOW_MS;
  const epoch = (s) => now / 1000 - s;
  assert.equal(ctx.isHandshakeStale(epoch(58), now), false);
  assert.equal(ctx.isHandshakeStale(epoch(135), now), false);
  assert.equal(ctx.isHandshakeStale(epoch(136), now), true);
  assert.equal(ctx.isHandshakeStale(epoch(3600), now), true);
  assert.equal(ctx.isHandshakeStale(0, now), true);
  assert.equal(ctx.isHandshakeStale("off", now), false);
  assert.equal(ctx.isHandshakeStale(undefined, now), false);
  // values Number() would coerce to 0
  assert.equal(ctx.isHandshakeStale(null, now), false);
  assert.equal(ctx.isHandshakeStale("", now), false);
  assert.equal(ctx.isHandshakeStale([], now), false);
  assert.equal(ctx.isHandshakeStale(true, now), false);
});

test("ipDisplay: prefers v4, falls back to v6, then --", () => {
  assert.equal(ctx.ipDisplay("10.66.0.2", "fe80::1"), "10.66.0.2");
  assert.equal(ctx.ipDisplay("", "fe80::1"), "fe80::1");
  assert.equal(ctx.ipDisplay("", ""), "--");
  assert.equal(ctx.ipDisplay(null, undefined), "--");
  assert.equal(ctx.ipDisplay("", null), "--");
});

test("buildPeers marks handshakeStale per peer", () => {
  const epoch = (s) => String(Math.round(NOW_MS / 1000 - s));
  const doc = {
    peerList: [PK_A, PK_B],
    endpoints: [],
    allowedIps: [],
    handshakes: [
      { key: PK_A, fields: [epoch(58)] },
      { key: PK_B, fields: [epoch(200)] },
    ],
    transfer: [],
    keepalives: [],
  };
  const peers = ctx.buildPeers(doc, NOW_MS);
  assert.equal(peers[0].handshakeStale, false);
  assert.equal(peers[1].handshakeStale, true);
  const neverDoc = {
    peerList: [PK_A],
    endpoints: [],
    allowedIps: [],
    handshakes: [{ key: PK_A, fields: ["0"] }],
    transfer: [],
    keepalives: [],
  };
  const neverPeer = ctx.buildPeers(neverDoc, NOW_MS)[0];
  assert.equal(neverPeer.handshake, "never");
  assert.equal(neverPeer.handshakeStale, true);
  const absentDoc = {
    peerList: [PK_A],
    endpoints: [],
    allowedIps: [],
    handshakes: [],
    transfer: [],
    keepalives: [],
  };
  const absentPeer = ctx.buildPeers(absentDoc, NOW_MS)[0];
  assert.equal(absentPeer.handshake, "--");
  assert.equal(absentPeer.handshakeStale, false);
});

// Settings ---------------------------------------------------------------------

test("normalizePrefs: defaults for missing, null and non-object input", () => {
  const d = {
    notifyExternalDrop: true,
    handshakeError: true,
    handshakeStaleAfterSec: 135,
    pollIntervalSec: 10,
  };
  assert.deepEqual({ ...ctx.normalizePrefs({}) }, d);
  assert.deepEqual({ ...ctx.normalizePrefs(null) }, d);
  assert.deepEqual({ ...ctx.normalizePrefs(undefined) }, d);
  assert.deepEqual({ ...ctx.normalizePrefs("x") }, d);
});

test("normalizePrefs: CLI strings are coerced", () => {
  const p = ctx.normalizePrefs({
    notifyExternalDrop: "false",
    handshakeError: "0",
    handshakeStaleAfterSec: "300",
  });
  assert.equal(p.notifyExternalDrop, false);
  assert.equal(p.handshakeError, false);
  assert.equal(p.handshakeStaleAfterSec, 300);
  const q = ctx.normalizePrefs({
    notifyExternalDrop: " TRUE ",
    handshakeError: "on",
  });
  assert.equal(q.notifyExternalDrop, true);
  assert.equal(q.handshakeError, true);
});

test("normalizePrefs: invalid values fall back, out-of-range integers clamp", () => {
  assert.equal(ctx.normalizePrefs({ notifyExternalDrop: "maybe" }).notifyExternalDrop, true);
  assert.equal(ctx.normalizePrefs({ handshakeError: 2 }).handshakeError, true);
  assert.equal(ctx.normalizePrefs({ handshakeStaleAfterSec: 60 }).handshakeStaleAfterSec, 120);
  assert.equal(ctx.normalizePrefs({ handshakeStaleAfterSec: 10 ** 9 }).handshakeStaleAfterSec, 86400);
  assert.equal(ctx.normalizePrefs({ handshakeStaleAfterSec: 150.5 }).handshakeStaleAfterSec, 135);
  assert.equal(ctx.normalizePrefs({ handshakeStaleAfterSec: "abc" }).handshakeStaleAfterSec, 135);
  assert.equal(ctx.normalizePrefs({ handshakeStaleAfterSec: "" }).handshakeStaleAfterSec, 135);
  assert.equal(ctx.normalizePrefs({ handshakeStaleAfterSec: true }).handshakeStaleAfterSec, 135);
  assert.equal(ctx.normalizePrefs({ handshakeStaleAfterSec: 120 }).handshakeStaleAfterSec, 120);
});

test("normalizePrefs: pollIntervalSec is a whole number of seconds in 1..3600", () => {
  const poll = (v) => ctx.normalizePrefs({ pollIntervalSec: v }).pollIntervalSec;
  assert.equal(poll("5"), 5);
  assert.equal(poll(1), 1);
  assert.equal(poll(0), 1);
  assert.equal(poll(-3), 1);
  assert.equal(poll(99999), 3600);
  assert.equal(poll(1.5), 10);
  assert.equal(poll("fast"), 10);
  assert.equal(poll(undefined), 10);
});

test("samePrefs compares normalized values", () => {
  assert.equal(ctx.samePrefs({}, { notifyExternalDrop: "true", handshakeStaleAfterSec: "135" }), true);
  assert.equal(ctx.samePrefs({}, { handshakeStaleAfterSec: 300 }), false);
  assert.equal(ctx.samePrefs({ handshakeError: false }, {}), false);
  assert.equal(ctx.samePrefs({ pollIntervalSec: "10" }, {}), true);
  assert.equal(ctx.samePrefs({ pollIntervalSec: 1 }, {}), false);
});

test("isHandshakeStale honours a custom threshold", () => {
  const epoch = (s) => NOW_MS / 1000 - s;
  assert.equal(ctx.isHandshakeStale(epoch(200), NOW_MS, 300), false);
  assert.equal(ctx.isHandshakeStale(epoch(301), NOW_MS, 300), true);
  assert.equal(ctx.isHandshakeStale(epoch(136), NOW_MS, undefined), true);
});

test("isHandshakeStale: a never-completed handshake waits out the threshold after the up", () => {
  const upAgo = (s) => NOW_MS - s * 1000;
  // just up: no peer has had the chance to shake hands
  assert.equal(ctx.isHandshakeStale(0, NOW_MS, 135, upAgo(1)), false);
  assert.equal(ctx.isHandshakeStale("0", NOW_MS, 135, upAgo(135)), false);
  assert.equal(ctx.isHandshakeStale(0, NOW_MS, 135, upAgo(136)), true);
  assert.equal(ctx.isHandshakeStale(0, NOW_MS, 300, upAgo(200)), false);
  // unknown up time: stale at once, as before
  assert.equal(ctx.isHandshakeStale(0, NOW_MS, 135, 0), true);
  assert.equal(ctx.isHandshakeStale(0, NOW_MS, 135, undefined), true);
  // a real handshake ignores the up time
  assert.equal(ctx.isHandshakeStale(NOW_MS / 1000 - 200, NOW_MS, 135, upAgo(1)), true);
  assert.equal(ctx.isHandshakeStale(NOW_MS / 1000 - 58, NOW_MS, 135, upAgo(3600)), false);
});

test("buildPeers and restalePeers pass the up time through", () => {
  const doc = {
    peerList: [PK_A],
    endpoints: [],
    allowedIps: [],
    handshakes: [{ key: PK_A, fields: ["0"] }],
    transfer: [],
    keepalives: [],
  };
  const fresh = ctx.buildPeers(doc, NOW_MS, 135, NOW_MS - 5000);
  assert.equal(fresh[0].handshake, "never");
  assert.equal(fresh[0].handshakeStale, false);
  assert.equal(ctx.restalePeers(fresh, NOW_MS, 135, NOW_MS - 200000)[0].handshakeStale, true);
  assert.equal(ctx.restalePeers(fresh, NOW_MS, 300, NOW_MS - 200000)[0].handshakeStale, false);
});

test("a stub peer that never shook hands reads never", () => {
  const r = runStubStep("latest-handshakes", "never");
  const doc = {
    peerList: ["ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ="],
    handshakes: ctx.parsePeerTable(r.stdout, 1),
  };
  const p = ctx.buildPeers(doc, Date.now(), 135, Date.now())[0];
  assert.equal(p.handshake, "never");
  assert.equal(p.handshakeStale, false);
});

test("buildPeers uses the threshold; restalePeers recomputes it from the raw epoch", () => {
  const epoch = (s) => String(Math.round(NOW_MS / 1000 - s));
  const doc = {
    peerList: [PK_A, PK_B, PK_X],
    endpoints: [],
    allowedIps: [],
    handshakes: [
      { key: PK_A, fields: [epoch(200)] },
      { key: PK_B, fields: ["0"] },
    ],
    transfer: [],
    keepalives: [],
  };
  const peers = ctx.buildPeers(doc, NOW_MS, 300);
  assert.deepEqual(
    [...peers].map((p) => p.handshakeStale),
    [false, true, false],
  );
  assert.equal(peers[2].handshakeEpoch, null);
  const tighter = ctx.restalePeers(peers, NOW_MS, 150);
  assert.deepEqual(
    [...tighter].map((p) => p.handshakeStale),
    [true, true, false],
  );
  assert.equal(peers[0].handshakeStale, false, "input left untouched");
  assert.equal(tighter[0].endpoint, peers[0].endpoint);
  assert.deepEqual([...ctx.stalePeerKeys(tighter)], [peers[0].shortKey, peers[1].shortKey]);
  assert.deepEqual([...ctx.stalePeerKeys(null)], []);
});

test("handshakeErrorMessage: stable text, one peer named, several counted, within toast budget", () => {
  const key = ctx.shortKey(PK_A);
  const one = ctx.handshakeErrorMessage([key], 135);
  assert.equal(one, `Peer ${key} has had no handshake for over 2m 15s`);
  assert.equal(ctx.handshakeErrorMessage([key, key, key], 86400), "3 peers have had no handshake for over 1d");
  assert.equal(ctx.handshakeErrorMessage([], 135), "");
  assert.ok(ctx.handshakeErrorMessage([key], 86399).length <= 100);
});

test("classifyDrop: an external drop with reporting off is ignored", () => {
  assert.equal(ctx.classifyDrop("down", true, false, false, false), "ignored");
  assert.equal(ctx.classifyDrop("down", true, false, false, true), "external");
  assert.equal(ctx.classifyDrop("down", true, false, true, false), "expected");
  assert.equal(ctx.classifyDrop("down", false, false, false, false), "none");
});

test("derivedLastError: handshake has the lowest priority", () => {
  assert.equal(ctx.derivedLastError({ peerError: "p", handshakeError: "h" }), "p");
  assert.equal(ctx.derivedLastError({ handshakeError: "h" }), "h");
});

test("manifest defaults match PREF_DEFAULTS", () => {
  const manifest = JSON.parse(fs.readFileSync(`${__dirname}/../manifest.json`, "utf8"));
  assert.deepEqual(manifest.barWidget.defaults, { ...ctx.PREF_DEFAULTS });
});

// The widget gets no manifest, so it spells its own id; the harness does the
// same to make the drop toast's click argv real.
test("Panel.qml and the harness spell the plugin id exactly as the manifest does", () => {
  const manifest = JSON.parse(fs.readFileSync(`${__dirname}/../manifest.json`, "utf8"));
  for (const file of ["Panel.qml", "tests/harness/harness.qml"]) {
    const src = fs.readFileSync(`${__dirname}/../${file}`, "utf8");
    assert.match(src, new RegExp(`pluginId: "${manifest.id}"`), `${file} spells a different id`);
  }
});
