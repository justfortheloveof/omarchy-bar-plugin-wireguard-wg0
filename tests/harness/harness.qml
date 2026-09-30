import QtQuick
import Quickshell
import "Model.js" as Model

// Stub-driven harness for Service.qml; run it through tests/harness/run.sh.
//
// HARNESS_SCENARIO picks the scenario; HARNESS_BIN_DIR, HARNESS_ACTION_MS and
// HARNESS_POLL_MS (0 = use the pollIntervalSec setting) and HARNESS_PREFS
// configure the service. Each scenario is a phase machine on a
// 100 ms ticker that ends with PASS/FAIL <sNN> and Qt.exit. Scenarios use the
// service's public API, except where a private field is the only evidence
// (CommandProcess: _runs, _reapingCount, _nextToken; Service: _expectDown,
// _peerGen, _sawUp, _notifyKeys, _upSinceMs, _statusQueued).
ShellRoot {
    id: h

    // What the shell injects in production, so the toast's click argv is real.
    readonly property string pluginId: "io.github.justfortheloveof.wireguard-wg0"
    readonly property string omarchyPath: "/usr/share/omarchy"

    property string scn: Quickshell.env("HARNESS_SCENARIO") || "vehicle"
    property string binDir: Quickshell.env("HARNESS_BIN_DIR") || "tests/stub/"
    property int actionMs: parseInt(Quickshell.env("HARNESS_ACTION_MS") || "30000")
    property int pollMs: parseInt(Quickshell.env("HARNESS_POLL_MS") || "600000")

    property string phase: "boot"
    property int ticks: 0
    property int window: 140 // scenario cap in ticks (~14 s)

    // Scenario scratch, declared once so every branch can write them.
    property bool phaseWasDown: false
    property bool s2Checked: false
    property int genBefore: -1
    property int settleT: 0
    property int secondT: 0
    property int attemptT: 0
    property int timeoutT: 0
    property int run2Start: 0
    property int seenPeers: -1
    property string s13Msg: ""
    property int s16Start: 0
    property int s19At: 0
    property int s20At: 0
    property int s20Runs: 0
    property int s28Polls: 0
    property bool s28WasBusy: false

    Service {
        id: svc
        binDir: h.binDir
        notifyBin: h.binDir + "omarchy-notification-send"
        actionTimeoutMs: h.actionMs
        pollIntervalMs: h.pollMs
        omarchyPath: h.omarchyPath
        manifest: ({
                id: h.pluginId
            })
        // HARNESS_PREFS: raw settings JSON, applied before any poll result.
        Component.onCompleted: {
            var raw = Quickshell.env("HARNESS_PREFS");
            if (raw)
                applyPrefs(JSON.parse(raw));
        }
    }

    function fail(reason) {
        print("FAIL " + h.scn + ": " + reason);
        Qt.exit(1);
    }

    function pass(detail) {
        print("PASS " + h.scn + ": " + detail);
        Qt.exit(0);
    }

    // Lanes are found by objectName; QML ids are file-local.
    function command(name) {
        for (var i = 0; i < svc.children.length; i++) {
            var c = svc.children[i];
            if (c.objectName === name)
                return c;
        }
        return null;
    }

    // Cache them per scenario run.
    property var cmdStatus: null
    property var cmdAction: null
    property var cmdPeers: null
    function resolveCommands() {
        if (!h.cmdStatus) {
            h.cmdStatus = h.command("statusCommand");
            h.cmdAction = h.command("actionCommand");
            h.cmdPeers = h.command("peersQuery");
            if (!h.cmdStatus || !h.cmdAction || !h.cmdPeers) {
                h.fail("did not resolve the three command lanes");
                return false;
            }
        }
        return true;
    }

    // The status argv Service.qml spawns; s01/s02 force-start the lane with it.
    function ipArgs() {
        return ["/usr/bin/env", "LC_ALL=C", h.binDir + "ip", "-j", "addr", "show", "dev", "wg0"];
    }

    // Display commands, read from the service so tests quote what it builds.
    function ipCmd() {
        return svc.statusCmd();
    }

    function quickCmd(direction) {
        return svc.actionCmd(direction);
    }

    // Reject an unusable HARNESS_ACTION_MS up front; otherwise the service
    // falls back to 15 s and the scenario only fails as a tick time-out.
    function actionWatchdogUsable(scn) {
        if (!(h.actionMs > 0) || h.actionMs >= 30000) {
            h.fail("HARNESS_ACTION_MS must be a positive value under 30000 for " + scn + " (got " + h.actionMs + ")");
            return false;
        }
        return true;
    }

    Timer {
        id: ticker
        interval: 100
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            h.ticks++;
            if (h.ticks > h.window) {
                h.fail("tick time-out in phase '" + h.phase + "'");
                return;
            }
            if (!h.resolveCommands())
                return;
            if (!h.step())
                ticker.stop();
        }
    }

    function step() {
        switch (h.scn) {
        case "s01":
            return stepS01();
        case "s02":
            return stepS02();
        case "s03":
            return stepS03();
        case "s04":
            return stepS04();
        case "s05":
            return stepS05();
        case "s06":
            return stepS06();
        case "s07":
            return stepS07();
        case "s08":
            return stepS08();
        case "s09":
            return stepS09();
        case "s10":
            return stepS10();
        case "s11":
            return stepS11();
        case "s12":
            return stepS12();
        case "s13":
            return stepS13();
        case "s14":
            return stepS14();
        case "s15":
            return stepS15();
        case "s16":
            return stepS16();
        case "s17":
            return stepS17();
        case "s18":
            return stepS18();
        case "s19":
            return stepS19();
        case "s20":
            return stepS20();
        case "s21":
            return stepS21();
        case "s22":
            return stepS22();
        case "s23":
            return stepS23();
        case "s24":
            return stepS24();
        case "s25":
            return stepS25();
        case "s26":
            return stepS26();
        case "s27":
            return stepS27();
        case "s28":
            return stepS28();
        case "s29":
            return stepS29();
        case "s30":
            return stepS30();
        case "s31":
            return stepS31();
        }
        h.fail("unknown scenario '" + h.scn + "'");
        return false;
    }

    // s01: a refresh during an action starts no poll, and a forced mid-action
    //      status result does not clear `desired`. run.sh: ip==3, wgq==1, nf==0.
    function stepS01() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "toggle-down";
            return true;
        case "toggle-down":
            svc.toggle(); // up -> down
            h.phase = "in-action";
            return true;
        case "in-action":
            if (!h.cmdAction.busy)
                return true;
            h.phase = "mid-forced";
            return true;
        case "mid-forced":
            // Force a status poll mid-action; it must not clear desired.
            h.cmdStatus.start(h.ipArgs(), 8000);
            h.phase = "mid-hold";
            return true;
        case "mid-hold":
            if (h.cmdStatus.busy)
                return true; // forced status still in flight
            if (svc.desired !== "down") {
                h.fail("forced mid-action status cleared desired ('" + svc.desired + "')");
                return false;
            }
            h.phase = "mid-refresh";
            return true;
        case "mid-refresh":
            // A refresh during the action must not start ip.
            if (!h.cmdAction.busy)
                return true; // action should still be running
            svc.refresh();
            if (h.cmdStatus.busy) {
                h.fail("refresh started a status during the action");
                return false;
            }
            if (svc.desired !== "down") {
                h.fail("refresh lost desired ('" + svc.desired + "')");
                return false;
            }
            h.phase = "wait-done";
            return true;
        case "wait-done":
            if (h.cmdAction.busy)
                return true;
            if (svc.desired !== "") {
                h.fail("desired not cleared by the action completion");
                return false;
            }
            h.phase = "verify";
            return true;
        case "verify":
            if (svc.tunnelState === "down" && svc.desired === "" && svc.statusError === "") {
                h.pass("refresh during the action started no poll; the verification poll covered it; desired survived");
                return false;
            }
            if (svc.tunnelState === "error") {
                h.fail("unexpected error state after down");
                return false;
            }
            return true;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s02: a failed down keeps its direction even when a stale status lands
    //      mid-action. run.sh: nf==1 (the failure).
    function stepS02() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "toggle-down";
            return true;
        case "toggle-down":
            svc.toggle(); // up -> down; wg-quick fails (delayed)
            h.phase = "in-action";
            return true;
        case "in-action":
            if (!h.cmdAction.busy)
                return true;
            h.phase = "mid-forced";
            return true;
        case "mid-forced":
            h.cmdStatus.start(h.ipArgs(), 8000); // stale status, mid-failure
            h.phase = "mid-hold";
            return true;
        case "mid-hold":
            if (h.cmdStatus.busy)
                return true; // wait for the forced status to land
            // Checked as soon as the stale status lands, before the action completes.
            if (!h.s2Checked) {
                h.s2Checked = true;
                if (svc.desired !== "down") {
                    h.fail("stale status stole desired ('" + svc.desired + "')");
                    return false;
                }
            }
            if (h.cmdAction.busy)
                return true;
            h.phase = "check-error";
            return true;
        case "check-error":
            if (svc.actionError === "") {
                h.fail("no actionError after failed down");
                return false;
            }
            // The message quotes the down command.
            var expected = Model.cmdFail(h.quickCmd("down"), 1, false);
            if (svc.actionError !== expected) {
                h.fail("actionError is not the down-flavoured failure: '" + svc.actionError + "' vs '" + expected + "'");
                return false;
            }
            h.pass("failed down reported with the down command quoted despite stale status");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s03: an action timeout clears desired, publishes the timeout and frees
    //      both lanes. run.sh: nf==1.
    function stepS03() {
        switch (h.phase) {
        case "boot":
            if (!h.actionWatchdogUsable("s03"))
                return false;
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "toggle-down";
            return true;
        case "toggle-down":
            h.phaseWasDown = true;
            svc.toggle(); // up -> down; wg-quick hangs past the watchdog
            h.phase = "in-action";
            return true;
        case "in-action":
            if (!h.cmdAction.busy)
                return true;
            h.phase = "wait-timeout";
            return true;
        case "wait-timeout":
            if (svc.desired !== "" || h.cmdAction.busy)
                return true;
            if (!h.phaseWasDown) {
                h.fail("desired was never set to 'down' before the timeout");
                return false;
            }
            if (svc.actionError === "") {
                h.fail("no actionError after timeout");
                return false;
            }
            // quotes the down command that hung
            var expected = Model.cmdFail(h.quickCmd("down"), 0, true);
            if (svc.actionError !== expected) {
                h.fail("timeout message mismatch: '" + svc.actionError + "' vs '" + expected + "'");
                return false;
            }
            h.phase = "check-verify";
            return true;
        case "check-verify":
            if (h.cmdStatus.busy || h.cmdAction.busy)
                return true;
            if (svc.tunnelState === "down" && svc.desired === "" && svc.statusError === "") {
                // The verify confirmed the down the timed-out action was after.
                if (svc.actionError !== "") {
                    h.fail("the confirmed down did not clear the stale timeout: '" + svc.actionError + "'");
                    return false;
                }
                h.pass("action timed out; desired cleared once; timeout message published; the confirmed down cleared it");
                return false;
            }
            return true;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s04: an action accepted mid-chain invalidates the chain: no peers, no
    //      peerError, no notification.
    function stepS04() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-chain";
            return true;
        case "wait-chain":
            if (!h.cmdPeers.busy)
                return true; // chain is in flight
            h.phase = "toggle-down";
            return true;
        case "toggle-down":
            h.genBefore = svc._peerGen;
            svc.toggle(); // up -> down while the chain still runs
            h.phase = "in-action";
            return true;
        case "in-action":
            if (!h.cmdAction.busy)
                return true;
            h.phase = "wait-done";
            return true;
        case "wait-done":
            if (svc.desired !== "" || h.cmdAction.busy)
                return true;
            if (svc._peerGen <= h.genBefore) {
                h.fail("action did not bump the generation");
                return false;
            }
            if (svc.peers.length !== 0) {
                h.fail("stale chain repopulated peers early: " + svc.peers.length);
                return false;
            }
            h.phase = "verify";
            return true;
        case "verify":
            // Let the stale chain drain before passing.
            if (h.cmdPeers.busy)
                return true;
            if (svc.tunnelState !== "down")
                return true;
            if (svc.peers.length !== 0) {
                h.fail("stale chain repopulated peers: " + svc.peers.length);
                return false;
            }
            if (svc.peerError !== "") {
                h.fail("stale chain published a peer error: '" + svc.peerError + "'");
                return false;
            }
            h.settleT = h.ticks;
            h.phase = "settle";
            return true;
        case "settle":
            if (h.ticks - h.settleT < 10)
                return true;
            if (svc.peers.length !== 0) {
                h.fail("late chain step repopulated peers");
                return false;
            }
            if (svc.peerError !== "") {
                h.fail("late chain step set peerError");
                return false;
            }
            h.pass("action accepted mid-chain; stale results dropped; no peerError, no notify");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s05: a stale chain cannot repopulate peers after our own down, and that
    //      down does not latch a drop.
    function stepS05() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-chain";
            return true;
        case "wait-chain":
            if (!h.cmdPeers.busy)
                return true;
            h.phase = "flip-down";
            return true;
        case "flip-down":
            svc.toggle(); // up -> down, its verification consumes ip down
            h.phase = "post-down";
            return true;
        case "post-down":
            if (svc.tunnelState !== "down")
                return true;
            if (svc.peers.length !== 0) {
                h.fail("peers repopulated after status flipped down: " + svc.peers.length);
                return false;
            }
            if (svc.peerError !== "") {
                h.fail("stale chain set peerError: '" + svc.peerError + "'");
                return false;
            }
            if (svc.droppedExternally) {
                h.fail("our own down was latched as an outside drop");
                return false;
            }
            if (svc.lastError !== "") {
                h.fail("a plain down published an error: '" + svc.lastError + "'");
                return false;
            }
            h.settleT = h.ticks;
            h.phase = "settle";
            return true;
        case "settle":
            // Let the in-flight chain drain fully first.
            if (h.cmdPeers.busy)
                return true;
            if (h.ticks - h.settleT < 10)
                return true;
            if (svc.peers.length !== 0) {
                h.fail("late chain step repopulated peers");
                return false;
            }
            if (svc.peerError !== "") {
                h.fail("late chain step set peerError");
                return false;
            }
            h.pass("status flip mid-chain dropped the stale results; peers stayed empty; our own down did not latch");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s06: a peer failure while up is reported once; the repeat is deduped.
    function stepS06() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-report";
            return true;
        case "wait-report":
            if (svc.peerError === "")
                return true;
            if (svc.lastError !== svc.peerError) {
                h.fail("lastError not the peer channel: '" + svc.lastError + "'");
                return false;
            }
            h.secondT = h.ticks;
            h.phase = "wait-second";
            return true;
        case "wait-second":
            // Allow the confirm-up rerun of the chain to fail identically again.
            if (h.ticks - h.secondT < 15)
                return true;
            h.pass("peer failure reported with peerError; the identical repeat was deduplicated");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s07: a peer failure followed by an outside drop is discarded; only the
    //      drop notifies. run.sh: nf==1.
    function stepS07() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-drop";
            return true;
        case "wait-drop":
            // Enough ticks for stash -> refresh -> confirm-down to settle.
            if (h.ticks < 15)
                return true;
            if (svc.tunnelState !== "down") {
                h.fail("status did not report down");
                return false;
            }
            if (svc.peerError !== "") {
                h.fail("peerError set on a drop: '" + svc.peerError + "'");
                return false;
            }
            if (svc.lastError !== Model.externalDropMessage("wg0")) {
                h.fail("lastError is not the drop message: '" + svc.lastError + "'");
                return false;
            }
            h.pass("peer failure dropped silently on a down; the only error is the outside drop");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s08: no action starts from `error`. run.sh: wgq==0, nf==1 (the ip error).
    function stepS08() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-error";
            return true;
        case "wait-error":
            if (svc.tunnelState !== "error")
                return true;
            if (svc.statusError === "") {
                h.fail("the ip error published no statusError");
                return false;
            }
            h.phase = "attempt";
            return true;
        case "attempt":
            h.attemptT = h.ticks;
            svc.toggle();
            svc.up();
            svc.down();
            h.phase = "check";
            return true;
        case "check":
            if (svc.desired !== "") {
                h.fail("action started from error state (desired '" + svc.desired + "')");
                return false;
            }
            if (h.cmdAction.busy) {
                h.fail("actionCommand busy after refusal");
                return false;
            }
            if (h.ticks - h.attemptT < 5)
                return true;
            h.pass("toggle/up/down all refused from error state; no process started");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s09: a wg-quick that ignores SIGTERM is SIGKILLed after the grace period,
    //      and the lane works again.
    function stepS09() {
        switch (h.phase) {
        case "boot":
            if (!h.actionWatchdogUsable("s09"))
                return false;
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "toggle-down";
            return true;
        case "toggle-down":
            svc.toggle(); // down; wg-quick ignores TERM
            h.phase = "in-action";
            return true;
        case "in-action":
            if (!h.cmdAction.busy)
                return true;
            h.timeoutT = h.ticks;
            h.phase = "wait-timeout";
            return true;
        case "wait-timeout":
            if (svc.desired !== "" || h.cmdAction.busy)
                return true;
            h.phase = "wait-reap";
            return true;
        case "wait-reap":
            // Only the reaper's SIGKILL ends the child; wait for its record to go.
            if (Object.keys(h.cmdAction._runs).length !== 0) {
                if (h.ticks - h.timeoutT > 60) {
                    h.fail("timed-out child never reaped (still in _runs)");
                    return false;
                }
                return true;
            }
            if (h.cmdAction.busy) {
                h.fail("command still busy after SIGKILL");
                return false;
            }
            if (h.cmdAction._reapingCount !== 0) {
                h.fail("reaper still armed after the child was reaped");
                return false;
            }
            h.phase = "later-wait-up";
            return true;
        case "later-wait-up":
            // The timeout's own verify (ip up) has settled; toggle again.
            if (svc.tunnelState !== "up")
                return true;
            svc.toggle(); // up -> down again; wg-quick ok now
            h.phase = "later-wait";
            return true;
        case "later-wait":
            if (svc.desired !== "" || h.cmdAction.busy)
                return true;
            h.phase = "later-verify";
            return true;
        case "later-verify":
            if (svc.tunnelState === "down" && svc.desired === "" && svc.actionError === "") {
                h.pass("SIGTERM-ignoring child was reaped; later run completed cleanly");
                return false;
            }
            return true;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s10: a late exit from a timed-out run does not complete the next run.
    function stepS10() {
        switch (h.phase) {
        case "boot":
            if (!h.actionWatchdogUsable("s10"))
                return false;
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "run1";
            return true;
        case "run1":
            svc.toggle(); // down; wg-quick hangs ignoring TERM
            h.phase = "run1-wait-t";
            return true;
        case "run1-wait-t":
            if (!h.cmdAction.busy)
                return true;
            h.timeoutT = h.ticks;
            h.phase = "run1-timeout";
            return true;
        case "run1-timeout":
            if (svc.desired !== "" || h.cmdAction.busy)
                return true;
            h.phase = "run2-wait-down";
            return true;
        case "run2-wait-down":
            // The timeout's verify ran ip down; wait for reality to settle.
            if (svc.tunnelState !== "down")
                return true;
            svc.toggle(); // down -> up; wg-quick ok delay=3000 (run2)
            h.run2Start = h.ticks;
            h.phase = "run2-in-flight";
            return true;
        case "run2-in-flight":
            // run1's SIGKILL lands ~2 s into run2; run2 must stay busy throughout.
            if (h.ticks - h.run2Start >= 22) {
                h.phase = "run2-done";
                return true;
            }
            if (!h.cmdAction.busy) {
                h.fail("run2 completed before its delay (late exit poisoned it)");
                return false;
            }
            if (svc.desired !== "up") {
                h.fail("desired lost during run2 ('" + svc.desired + "')");
                return false;
            }
            return true;
        case "run2-done":
            if (svc.desired !== "" || h.cmdAction.busy)
                return true;
            if (svc.tunnelState !== "up") {
                h.fail("run2 verify did not report up");
                return false;
            }
            h.pass("late exit from the timed-out run did not complete run2");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s11: a clean poll clears statusError but not actionError while the
    //      tunnel is not in the failed action's target state; a later
    //      successful action clears it. run.sh: nf==2.
    function stepS11() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "fail-down";
            return true;
        case "fail-down":
            svc.toggle(); // down; wg-quick fails
            h.phase = "fail-wait";
            return true;
        case "fail-wait":
            if (svc.actionError === "")
                return true;
            // Wait for the failed action's verify so the next poll is a separate one.
            if (h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "error")
                return true;
            h.phase = "clean-poll";
            return true;
        case "clean-poll":
            // Only statusError clears; the action failure keeps the error card.
            svc.refresh();
            h.phase = "clean-wait";
            return true;
        case "clean-wait":
            if (h.cmdStatus.busy)
                return true; // wait for the clean result to land
            if (svc.statusError !== "") {
                h.fail("clean poll left statusError set: '" + svc.statusError + "'");
                return false;
            }
            if (svc.tunnelState !== "up") {
                h.fail("clean poll did not report up");
                return false;
            }
            if (svc.actionError === "") {
                h.fail("clean status cleared actionError");
                return false;
            }
            if (svc.lastError !== svc.actionError) {
                h.fail("lastError not the surviving actionError");
                return false;
            }
            h.phase = "succeed";
            return true;
        case "succeed":
            svc.toggle(); // up -> down; wg-quick ok
            h.phase = "succeed-wait";
            return true;
        case "succeed-wait":
            if (svc.desired !== "" || h.cmdAction.busy)
                return true;
            h.phase = "succeed-verify";
            return true;
        case "succeed-verify":
            if (svc.actionError !== "") {
                h.fail("successful action did not clear actionError");
                return false;
            }
            if (svc.lastError !== "") {
                h.fail("box not hidden after recovery: '" + svc.lastError + "'");
                return false;
            }
            h.pass("clean status cleared only statusError; actionError survived until success");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s12: a peer failure keeps the last-known peers and sets peerError.
    function stepS12() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-peers";
            return true;
        case "wait-peers":
            if (svc.peers.length === 0 || svc.tunnelState !== "up")
                return true;
            h.seenPeers = svc.peers.length;
            h.phase = "trigger-fail";
            return true;
        case "trigger-fail":
            svc.refresh(); // ip up consumed; chain reruns and fails
            h.phase = "wait-report";
            return true;
        case "wait-report":
            if (svc.peerError !== "") {
                if (svc.peers.length !== h.seenPeers) {
                    h.fail("peer failure cleared the stale list: " + svc.peers.length + " (was " + h.seenPeers + ")");
                    return false;
                }
                if (svc.lastError !== svc.peerError) {
                    h.fail("lastError not the peer channel");
                    return false;
                }
                h.pass("peer failure kept last-known peers (" + svc.peers.length + ") with peerError explaining");
                return false;
            }
            if (h.ticks > 60) {
                h.fail("no peerError reported");
                return false;
            }
            return true;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s13: a peer failure recurring across our down/up cycle notifies once:
    //      leaving up clears the card but keeps the dedupe key.
    function stepS13() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-report";
            return true;
        case "wait-report":
            if (svc.peerError === "")
                return true;
            if (svc.lastError !== svc.peerError) {
                h.fail("lastError not the peer channel: '" + svc.lastError + "'");
                return false;
            }
            h.s13Msg = svc.peerError;
            h.phase = "toggle-down";
            return true;
        case "toggle-down":
            svc.toggle(); // up -> down; wg-quick ok
            h.phase = "wait-down";
            return true;
        case "wait-down":
            // Leaving up cleared the box in the same status result as the flip.
            if (svc.tunnelState !== "down" || svc.peerError !== "")
                return true;
            h.phase = "toggle-up";
            return true;
        case "toggle-up":
            svc.toggle(); // down -> up; wg-quick ok
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "wait-restore";
            return true;
        case "wait-restore":
            // The 2nd confirm re-published the identical message.
            if (svc.peerError !== h.s13Msg)
                return true;
            if (svc.lastError !== svc.peerError) {
                h.fail("lastError not the peer channel after restore: '" + svc.lastError + "'");
                return false;
            }
            h.secondT = h.ticks;
            h.phase = "hold";
            return true;
        case "hold":
            if (h.ticks - h.secondT < 15)
                return true;
            h.pass("storm: same peer failure notified once across a down/up cycle (per-channel dedupe key survived the action success)");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s14: an existing interface without UP is an error with its own message.
    //      run.sh: ip==2, nf==1.
    function stepS14() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "trigger-bad";
            return true;
        case "trigger-bad":
            svc.refresh(); // consumes ip up-down while up
            h.phase = "wait-error";
            return true;
        case "wait-error":
            if (svc.tunnelState !== "error")
                return true;
            if (svc.statusError !== Model.linkDownMessage("wg0")) {
                h.fail("link-down statusError was '" + svc.statusError + "'");
                return false;
            }
            if (svc.peers.length !== 0) {
                h.fail("bad ip payload left peers populated");
                return false;
            }
            if (svc.lastError !== svc.statusError) {
                h.fail("lastError not the status channel");
                return false;
            }
            h.settleT = h.ticks;
            h.phase = "settle";
            return true;
        case "settle":
            if (h.cmdPeers.busy)
                return true;
            if (h.ticks - h.settleT < 10)
                return true;
            if (svc.tunnelState !== "error") {
                h.fail("left error state unexpectedly");
                return false;
            }
            if (svc.peers.length !== 0) {
                h.fail("stale chain repopulated peers after bad payload");
                return false;
            }
            h.pass("link-down interface reported as an error, peers cleared, no chain started");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s15: an outside drop latches and notifies once, survives a refresh,
    //      clears on recovery, and a second drop notifies again.
    function stepS15() {
        var expected = Model.externalDropMessage("wg0");
        switch (h.phase) {
        case "boot":
            h.phase = "wait-peers";
            return true;
        case "wait-peers":
            if (svc.tunnelState !== "up" || svc.peers.length === 0)
                return true;
            h.phase = "drop";
            return true;
        case "drop":
            svc.refresh(); // nothing ran wg-quick: the tunnel went down by itself
            h.phase = "check-drop";
            return true;
        case "check-drop":
            if (h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "down") {
                h.fail("not down after the outside drop: " + svc.tunnelState);
                return false;
            }
            if (!svc.droppedExternally) {
                h.fail("the outside drop did not latch");
                return false;
            }
            if (svc.statusError !== expected) {
                h.fail("statusError is not the drop message: '" + svc.statusError + "'");
                return false;
            }
            if (svc.lastError !== expected) {
                h.fail("lastError is not the drop message");
                return false;
            }
            if (svc.actionError !== "" || svc.peerError !== "") {
                h.fail("the drop published another channel");
                return false;
            }
            if (svc.peers.length !== 0) {
                h.fail("the drop left peers populated: " + svc.peers.length);
                return false;
            }
            if (Model.statusRow(svc.tunnelState, false, "", svc.droppedExternally) !== "Error") {
                h.fail("the status row does not read as an error");
                return false;
            }
            if (!Model.canToggle(svc.tunnelState, false)) {
                h.fail("the toggle is refused from a latched drop");
                return false;
            }
            h.phase = "refresh-down";
            return true;
        case "refresh-down":
            svc.refresh(); // still down
            h.phase = "check-still";
            return true;
        case "check-still":
            if (h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "down" || !svc.droppedExternally) {
                h.fail("the latch did not survive a refresh while still down");
                return false;
            }
            if (svc.statusError !== expected) {
                h.fail("the drop message was lost on a clean down poll: '" + svc.statusError + "'");
                return false;
            }
            h.phase = "recover";
            return true;
        case "recover":
            svc.toggle(); // down -> up: the latch must not block the recovery
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.desired !== "" || h.cmdAction.busy)
                return true;
            h.phase = "check-up";
            return true;
        case "check-up":
            if (h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "up")
                return true; // the verification poll has not landed yet
            if (svc.droppedExternally) {
                h.fail("the latch survived the tunnel coming back up");
                return false;
            }
            if (svc.statusError !== "" || svc.lastError !== "") {
                h.fail("the drop message survived recovery: '" + svc.lastError + "'");
                return false;
            }
            h.phase = "second-drop";
            return true;
        case "second-drop":
            svc.refresh(); // up -> down again, with no toggle in between this time
            h.phase = "check-second";
            return true;
        case "check-second":
            if (h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "down" || !svc.droppedExternally) {
                h.fail("the second outside drop was not latched");
                return false;
            }
            if (svc.statusError !== expected) {
                h.fail("the second drop published a different message");
                return false;
            }
            h.pass("outside drop latched and notified once, survived a refresh, cleared on recovery, notified again");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s16: run1's late SIGKILL exit, inside run2's window, must not cancel
    //      run2's watchdog.
    function stepS16() {
        // Both runs time out with the same message, so the second is deduped.
        var expected = Model.cmdFail(h.quickCmd("down"), 0, true);
        switch (h.phase) {
        case "boot":
            if (!h.actionWatchdogUsable("s16"))
                return false;
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "run1";
            return true;
        case "run1":
            svc.toggle(); // up -> down; wg-quick hangs and ignores TERM
            h.phase = "run1-timeout";
            return true;
        case "run1-timeout":
            if (svc.desired !== "" || h.cmdAction.busy)
                return true; // run1's own watchdog has not fired yet
            if (svc.actionError !== expected) {
                h.fail("run1 did not time out: actionError '" + svc.actionError + "'");
                return false;
            }
            h.phase = "run1-verify";
            return true;
        case "run1-verify":
            // Verify says up, so run2 is a plain second toggle, started while run1 is
            // still being reaped.
            if (svc.tunnelState !== "up")
                return true;
            svc.toggle(); // up -> down again; wg-quick hangs (TERM would end it)
            h.s16Start = h.ticks;
            h.phase = "run2-in-flight";
            return true;
        case "run2-in-flight":
            // run1's SIGKILL lands during run2; run2 must stay busy with desired held.
            if (h.ticks - h.s16Start >= 22) {
                h.phase = "run2-timeout";
                return true;
            }
            if (!h.cmdAction.busy) {
                h.fail("run2 left the action lane " + (h.ticks - h.s16Start) + " ticks in, before the window closed");
                return false;
            }
            if (svc.desired !== "down") {
                h.fail("desired lost during run2 ('" + svc.desired + "')");
                return false;
            }
            return true;
        case "run2-timeout":
            // run2 ended on its own deadline: desired cleared, timeout published.
            if (svc.desired !== "" || h.cmdAction.busy)
                return true;
            if (svc.actionError !== expected) {
                h.fail("run2 did not time out: actionError '" + svc.actionError + "'");
                return false;
            }
            h.phase = "settle";
            return true;
        case "settle":
            // Both lanes idle; nothing of run1 left.
            if (h.cmdStatus.busy || h.cmdAction.busy)
                return true;
            if (svc.tunnelState !== "up") {
                h.fail("run2 verify did not report up (" + svc.tunnelState + ")");
                return false;
            }
            h.pass("run1's reaped exit did not disarm run2's watchdog; run2 timed out on its own deadline");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s17: an `up` result after our successful down clears _expectDown, so a
    //      later down is an outside drop.
    function stepS17() {
        var expected = Model.externalDropMessage("wg0");
        switch (h.phase) {
        case "boot":
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "toggle-down";
            return true;
        case "toggle-down":
            svc.toggle(); // up -> down; wg-quick ok, so this arms _expectDown...
            h.phase = "wait-ok";
            return true;
        case "wait-ok":
            // ...and the verification refresh it kicks off reports up again.
            if (svc.desired !== "" || h.cmdAction.busy)
                return true;
            if (h.cmdStatus.busy)
                return true; // the verification poll has not landed yet
            if (svc.tunnelState !== "up") {
                h.fail("the down action's verification did not report up (" + svc.tunnelState + ")");
                return false;
            }
            if (svc.droppedExternally) {
                h.fail("our own successful down latched as an outside drop");
                return false;
            }
            h.phase = "drop";
            return true;
        case "drop":
            svc.refresh(); // consumes ip down, with no toggle of ours pending
            h.phase = "check-drop";
            return true;
        case "check-drop":
            if (h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "down") {
                h.fail("not down after the outside drop: " + svc.tunnelState);
                return false;
            }
            if (!svc.droppedExternally) {
                h.fail("the outside drop was swallowed as expected (_expectDown survived the up)");
                return false;
            }
            if (svc.statusError !== expected) {
                h.fail("statusError is not the drop message: '" + svc.statusError + "'");
                return false;
            }
            if (svc.actionError !== "" || svc.peerError !== "") {
                h.fail("the drop published another channel: '" + svc.lastError + "'");
                return false;
            }
            if (Model.statusRow(svc.tunnelState, false, "", svc.droppedExternally) !== "Error") {
                h.fail("the status row does not read as an error");
                return false;
            }
            if (!Model.canToggle(svc.tunnelState, false)) {
                h.fail("the toggle is refused from a latched drop");
                return false;
            }
            h.pass("a successful down left no pending expectation; the later outside drop latched and notified");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s18: an unreadable poll between up and down does not hide the drop.
    //      run.sh: nf==2 (error and drop, separate dedupe keys).
    function stepS18() {
        var dropMsg = Model.externalDropMessage("wg0");
        // the stub's silent exit 2, quoted with the command the service built
        var readErr = Model.statusState("", "", 2, "wg0", h.ipCmd()).error;
        switch (h.phase) {
        case "boot":
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "unreadable";
            return true;
        case "unreadable":
            svc.refresh(); // consumes ip error while the tunnel is up
            h.phase = "check-unreadable";
            return true;
        case "check-unreadable":
            if (h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "error") {
                h.fail("the unreadable poll did not land on error (" + svc.tunnelState + ")");
                return false;
            }
            if (svc.droppedExternally) {
                h.fail("the unreadable poll latched a drop");
                return false;
            }
            if (svc.statusError !== readErr) {
                h.fail("statusError is not the read error: '" + svc.statusError + "'");
                return false;
            }
            h.phase = "drop";
            return true;
        case "drop":
            svc.refresh(); // consumes ip down: the drop the error hid
            h.phase = "check-drop";
            return true;
        case "check-drop":
            if (h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "down") {
                h.fail("not down after the outside drop: " + svc.tunnelState);
                return false;
            }
            if (!svc.droppedExternally) {
                h.fail("the unreadable poll swallowed the drop (the up memory was lost)");
                return false;
            }
            if (svc.statusError !== dropMsg) {
                h.fail("statusError is not the drop message: '" + svc.statusError + "'");
                return false;
            }
            if (svc.lastError !== dropMsg) {
                h.fail("lastError is not the drop message");
                return false;
            }
            if (svc.actionError !== "" || svc.peerError !== "") {
                h.fail("the drop published another channel: '" + svc.lastError + "'");
                return false;
            }
            if (Model.statusRow(svc.tunnelState, false, "", svc.droppedExternally) !== "Error") {
                h.fail("the status row does not read as an error");
                return false;
            }
            if (!Model.canToggle(svc.tunnelState, false)) {
                h.fail("the toggle is refused from a latched drop");
                return false;
            }
            h.pass("the unreadable poll kept the up memory; the down behind it latched and notified");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s19: the status watchdog firing on our down's verify does not clear
    //      _expectDown, so our late down is not reported as a drop.
    function stepS19() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (svc.tunnelState !== "up")
                return true;
            h.phase = "toggle-down";
            return true;
        case "toggle-down":
            svc.toggle(); // up -> down; wg-quick ok, so the arm is set...
            h.phase = "wait-action";
            return true;
        case "wait-action":
            if (svc.desired !== "" || h.cmdAction.busy)
                return true;
            h.s19At = h.ticks;
            h.phase = "wait-poll";
            return true;
        case "wait-poll":
            // The verify poll is delayed past the 4 s status watchdog.
            if (!h.cmdStatus.busy) {
                if (h.ticks - h.s19At > 40) {
                    h.fail("the successful down never started its verification poll");
                    return false;
                }
                return true;
            }
            h.phase = "wait-watchdog";
            return true;
        case "wait-watchdog":
            if (h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "error") {
                h.fail("the unreadable verification poll did not time out into error (" + svc.tunnelState + ")");
                return false;
            }
            if (svc.droppedExternally) {
                h.fail("the status watchdog latched a drop");
                return false;
            }
            if (svc.statusError === "") {
                h.fail("no statusError after the status watchdog");
                return false;
            }
            // the watchdog is a timeout, so it names the command and no code
            var wantErr = Model.cmdFail(h.ipCmd(), 0, true);
            if (svc.statusError !== wantErr) {
                h.fail("statusError is not the watchdog message: '" + svc.statusError + "' vs '" + wantErr + "'");
                return false;
            }
            if (svc.actionError !== "") {
                h.fail("the successful down published an actionError: '" + svc.actionError + "'");
                return false;
            }
            // Only the private _expectDown shows whether the arm survived.
            if (!svc._expectDown) {
                h.fail("the status watchdog disarmed the pending down");
                return false;
            }
            h.phase = "verify";
            return true;
        case "verify":
            svc.refresh(); // consumes ip down: our own down, reported late
            h.phase = "check-drop";
            return true;
        case "check-drop":
            if (h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "down") {
                h.fail("not down after our own late-landing action: " + svc.tunnelState);
                return false;
            }
            if (svc.droppedExternally) {
                h.fail("the arm was disarmed by the unreadable poll: our own down was blamed on something else");
                return false;
            }
            if (svc.statusError !== "" || svc.lastError !== "") {
                h.fail("the watchdog's error survived a clean down poll: '" + svc.lastError + "'");
                return false;
            }
            if (Model.statusRow("down", false, "", false) !== "Down") {
                h.fail("a plain down does not read as Down");
                return false;
            }
            if (!Model.canToggle(svc.tunnelState, false)) {
                h.fail("the toggle is refused after our own down");
                return false;
            }
            h.pass("the watchdog did not disarm the pending down; our own late down stayed unblamed");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s20: a refresh during an in-flight poll is queued and runs afterwards.
    //      run.sh: ip==2, nf==0.
    function stepS20() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-boot-poll";
            return true;
        case "wait-boot-poll":
            if (!h.cmdStatus.busy)
                return true; // the delayed boot poll has not started yet
            h.s20Runs = h.cmdStatus._nextToken; // status runs started so far
            h.s20At = h.ticks;
            h.phase = "request";
            return true;
        case "request":
            svc.refresh(); // lands on a busy lane: must be deferred, not dropped
            h.phase = "wait-deferred";
            return true;
        case "wait-deferred":
            // Count started runs, not busy: an instant stub can finish between samples.
            if (h.cmdStatus._nextToken > h.s20Runs) {
                h.phase = "settle";
                return true;
            }
            if (h.ticks - h.s20At > 40) {
                h.fail("the refresh during the in-flight poll was dropped (no second status poll started)");
                return false;
            }
            return true;
        case "settle":
            if (h.cmdStatus.busy)
                return true; // the deferred poll has not landed yet
            if (svc.tunnelState !== "up") {
                h.fail("the deferred poll did not report up (" + svc.tunnelState + ")");
                return false;
            }
            if (svc.droppedExternally) {
                h.fail("the deferred poll latched a drop");
                return false;
            }
            if (svc.statusError !== "") {
                h.fail("the deferred poll left statusError set: '" + svc.statusError + "'");
                return false;
            }
            h.pass("the refresh during the in-flight poll was deferred and ran as its own poll");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s21: an identical ip error notifies once; a readable poll re-arms it.
    //      run.sh: ip==4, nf==2 is the actual proof.
    function stepS21() {
        // the stub's silent exit 2, quoted with the command the service built
        var readErr = Model.statusState("", "", 2, "wg0", h.ipCmd()).error;
        switch (h.phase) {
        case "boot":
            h.phase = "wait-first";
            return true;
        case "wait-first":
            if (svc.tunnelState !== "error")
                return true;
            if (svc.statusError !== readErr) {
                h.fail("first error is not the ip failure: '" + svc.statusError + "'");
                return false;
            }
            if (svc.droppedExternally) {
                h.fail("an ip error latched a drop");
                return false;
            }
            h.phase = "again";
            return true;
        case "again":
            // Identical error; run.sh checks it was not notified again.
            if (h.cmdStatus.busy)
                return true;
            svc.refresh(); // consumes ip error #2
            h.secondT = h.ticks;
            h.phase = "hold";
            return true;
        case "hold":
            // Give a notification that should not have been sent time to arrive.
            if (h.ticks - h.secondT < 15)
                return true;
            if (svc.statusError !== readErr) {
                h.fail("the repeat changed the message: '" + svc.statusError + "'");
                return false;
            }
            if (svc.tunnelState !== "error") {
                h.fail("the repeat left the error state: '" + svc.tunnelState + "'");
                return false;
            }
            h.phase = "recover";
            return true;
        case "recover":
            if (h.cmdStatus.busy)
                return true;
            svc.refresh(); // consumes ip down: a clean down, nothing latched
            h.phase = "wait-down";
            return true;
        case "wait-down":
            if (h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "down") {
                h.fail("the recovery poll did not report down (" + svc.tunnelState + ")");
                return false;
            }
            if (svc.droppedExternally) {
                h.fail("the recovery down latched an outside drop");
                return false;
            }
            if (svc.statusError !== "" || svc.lastError !== "") {
                h.fail("a clean down published an error: '" + svc.lastError + "'");
                return false;
            }
            h.phase = "retrigger";
            return true;
        case "retrigger":
            // The clean down re-armed the key, so this one notifies.
            if (h.cmdStatus.busy)
                return true;
            svc.refresh(); // consumes ip error #3
            h.phase = "wait-again";
            return true;
        case "wait-again":
            if (svc.tunnelState !== "error")
                return true;
            if (svc.statusError !== readErr) {
                h.fail("the re-triggered error is not the ip failure: '" + svc.statusError + "'");
                return false;
            }
            h.phase = "settle";
            return true;
        case "settle":
            if (h.cmdStatus.busy)
                return true;
            if (h.ticks - h.secondT < 5)
                return true;
            h.pass("the identical ip error was notified once, and again after a clean down re-armed the key");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s22: notifyExternalDrop off (HARNESS_PREFS): an outside drop is a plain
    //      down. run.sh: ip==2, nf==0.
    function stepS22() {
        switch (h.phase) {
        case "boot":
            if (svc.prefs.notifyExternalDrop !== false) {
                h.fail("HARNESS_PREFS did not turn notifyExternalDrop off");
                return false;
            }
            h.phase = "wait-peers";
            return true;
        case "wait-peers":
            if (svc.tunnelState !== "up" || svc.peers.length === 0)
                return true;
            svc.refresh(); // the tunnel went down by itself
            h.phase = "check";
            return true;
        case "check":
            if (h.cmdStatus.busy || svc.tunnelState === "up")
                return true;
            if (svc.tunnelState !== "down") {
                h.fail("not down after the outside drop: " + svc.tunnelState);
                return false;
            }
            if (svc.droppedExternally) {
                h.fail("the drop latched with reporting off");
                return false;
            }
            if (svc.lastError !== "") {
                h.fail("the drop published an error: '" + svc.lastError + "'");
                return false;
            }
            if (svc._sawUp) {
                h.fail("the ignored drop did not consume the up memory");
                return false;
            }
            h.pass("with reporting off, the outside drop was a plain down: no latch, no error, no toast");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s23: turning notifyExternalDrop off clears a latched drop at once.
    //      run.sh: ip==2, nf==1 (the drop, before the change).
    function stepS23() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-peers";
            return true;
        case "wait-peers":
            if (svc.tunnelState !== "up" || svc.peers.length === 0)
                return true;
            svc.refresh();
            h.phase = "wait-latch";
            return true;
        case "wait-latch":
            if (h.cmdStatus.busy || !svc.droppedExternally)
                return true;
            svc.applyPrefs({
                notifyExternalDrop: "false"
            }); // CLI-style string
            if (svc.droppedExternally || svc.statusError !== "" || svc.lastError !== "") {
                h.fail("the latch survived turning reporting off: '" + svc.lastError + "'");
                return false;
            }
            if (svc._notifyKeys.status !== "") {
                h.fail("the drop's dedupe key was not re-armed");
                return false;
            }
            h.pass("turning reporting off cleared the latched drop, its error and its dedupe key");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s24: stale handshakes with the error on: one toast per episode across
    //      polls, cleared and re-armed by a looser threshold, raised again by a
    //      tighter one. run.sh: nf==2, both the handshake toast.
    function stepS24() {
        var msg = Model.handshakeErrorMessage([Model.shortKey("ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ=")], 135);
        switch (h.phase) {
        case "boot":
            h.phase = "wait-error";
            return true;
        case "wait-error":
            if (svc.handshakeError === "")
                return true;
            if (svc.handshakeError !== msg || svc.lastError !== msg) {
                h.fail("unexpected handshake error: '" + svc.handshakeError + "'");
                return false;
            }
            if (svc.tunnelState !== "up" || !Model.canToggle(svc.tunnelState, false)) {
                h.fail("a stale handshake changed the tunnel state: " + svc.tunnelState);
                return false;
            }
            h.secondT = 0;
            h.phase = "repoll";
            return true;
        case "repoll":
            // Two more full polls with the peer still stale: no second toast.
            if (h.cmdStatus.busy || h.cmdPeers.busy)
                return true;
            if (h.secondT >= 2) {
                h.phase = "loosen";
                return true;
            }
            h.secondT++;
            svc.refresh();
            return true;
        case "loosen":
            if (h.cmdStatus.busy || h.cmdPeers.busy)
                return true;
            if (svc.handshakeError !== msg) {
                h.fail("the error did not persist across polls: '" + svc.handshakeError + "'");
                return false;
            }
            svc.applyPrefs({
                handshakeStaleAfterSec: 7200
            });
            if (svc.handshakeError !== "" || svc.hasStaleHandshake) {
                h.fail("a looser threshold did not clear the error");
                return false;
            }
            if (svc._notifyKeys.handshake !== "") {
                h.fail("recovery did not re-arm the handshake toast");
                return false;
            }
            svc.applyPrefs({
                handshakeStaleAfterSec: 135
            });
            if (svc.handshakeError !== msg) {
                h.fail("the tighter threshold did not raise the error again");
                return false;
            }
            h.settleT = h.ticks;
            h.phase = "settle";
            return true;
        case "settle":
            if (h.ticks - h.settleT < 5)
                return true;
            h.pass("stale handshake raised one toast per episode, cleared and re-armed by the threshold");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s25: handshakeError off (HARNESS_PREFS): a stale peer is only flagged
    //      per peer; turning it on raises the error. run.sh: nf==1.
    function stepS25() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-peers";
            return true;
        case "wait-peers":
            if (svc.peers.length === 0 || h.cmdPeers.busy)
                return true;
            if (!svc.hasStaleHandshake) {
                h.fail("the stub peer is not stale");
                return false;
            }
            if (svc.handshakeError !== "" || svc.lastError !== "") {
                h.fail("the error is off but was published: '" + svc.lastError + "'");
                return false;
            }
            svc.applyPrefs({
                handshakeError: true
            });
            if (svc.handshakeError === "") {
                h.fail("turning the error on did not raise it");
                return false;
            }
            svc.applyPrefs({
                handshakeError: false
            });
            if (svc.handshakeError !== "" || svc._notifyKeys.handshake !== "") {
                h.fail("turning the error off did not clear and re-arm it");
                return false;
            }
            h.settleT = h.ticks;
            h.phase = "settle";
            return true;
        case "settle":
            if (h.ticks - h.settleT < 5)
                return true;
            h.pass("with the error off a stale peer published nothing; toggling the setting raised and cleared it");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s26: our own down ends the stale episode, so the next up notifies again.
    //      run.sh: wgq==2, nf==2.
    function stepS26() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-error";
            return true;
        case "wait-error":
            if (svc.handshakeError === "" || h.cmdPeers.busy)
                return true;
            svc.toggle(); // up -> down
            h.phase = "wait-down";
            return true;
        case "wait-down":
            if (svc.desired !== "" || h.cmdAction.busy || h.cmdStatus.busy)
                return true;
            if (svc.tunnelState !== "down" || svc.handshakeError !== "" || svc.droppedExternally) {
                h.fail("the down did not clear the handshake error cleanly: " + svc.tunnelState + " '" + svc.lastError + "'");
                return false;
            }
            svc.toggle(); // down -> up
            h.phase = "wait-again";
            return true;
        case "wait-again":
            if (svc.handshakeError === "" || h.cmdPeers.busy)
                return true;
            h.settleT = h.ticks;
            h.phase = "settle";
            return true;
        case "settle":
            if (h.ticks - h.settleT < 5)
                return true;
            h.pass("a down ended the stale episode; the next up notified again");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s27 (HARNESS_POLL_MS=0): the poll interval follows the setting. A
    //      longer one waits; a shorter one that has already elapsed polls at
    //      once. run.sh: ip==2.
    function stepS27() {
        var timer = null;
        for (var i = 0; i < svc.data.length; i++)
            if (svc.data[i] && svc.data[i].objectName === "pollTimer")
                timer = svc.data[i];
        switch (h.phase) {
        case "boot":
            if (!timer) {
                h.fail("pollTimer not found");
                return false;
            }
            if (timer.interval !== 10000) {
                h.fail("default interval is " + timer.interval + " ms, not 10000");
                return false;
            }
            h.phase = "wait-boot";
            return true;
        case "wait-boot":
            if (h.cmdStatus.busy || svc.tunnelState === "checking")
                return true;
            h.settleT = h.ticks;
            h.phase = "longer";
            return true;
        case "longer":
            if (h.ticks - h.settleT < 15) // 1.5 s since the boot poll
                return true;
            svc.applyPrefs({
                pollIntervalSec: "3600"
            });
            if (timer.interval !== 3600000) {
                h.fail("interval did not follow the setting: " + timer.interval);
                return false;
            }
            if (h.cmdStatus.busy) {
                h.fail("a longer interval polled at once");
                return false;
            }
            svc.applyPrefs({
                pollIntervalSec: 1
            });
            if (timer.interval !== 1000) {
                h.fail("interval did not follow the setting: " + timer.interval);
                return false;
            }
            if (!h.cmdStatus.busy) {
                h.fail("an elapsed shorter interval did not poll at once");
                return false;
            }
            svc.applyPrefs({
                pollIntervalSec: 3600
            });
            h.phase = "settle";
            return true;
        case "settle":
            if (h.cmdStatus.busy)
                return true;
            h.pass("the interval followed the setting; an elapsed shorter one polled at once, a longer one waited");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s28 (HARNESS_POLL_MS=1000, ip takes 2.5 s): ticks during a poll are
    //      skipped, never queued, so polls never run back to back.
    //      run.sh: ip <= 4 over ~8 s.
    function stepS28() {
        if (svc._statusQueued) {
            h.fail("a timer tick queued a poll");
            return false;
        }
        var busy = h.cmdStatus.busy;
        if (busy && !h.s28WasBusy)
            h.s28Polls++;
        // A poll starting on the very tick the last one ended is back to back.
        if (busy && !h.s28WasBusy && h.secondT === h.ticks) {
            h.fail("a poll started as soon as the previous one ended");
            return false;
        }
        if (!busy && h.s28WasBusy)
            h.secondT = h.ticks;
        h.s28WasBusy = busy;
        if (h.ticks < 80)
            return true;
        if (h.s28Polls < 2) {
            h.fail("the timer stopped polling (" + h.s28Polls + " polls)");
            return false;
        }
        h.pass("slow polls at a 1 s interval: " + h.s28Polls + " polls in 8 s, none queued by a tick");
        return false;
    }

    // s29: a failed up keeps its error while the tunnel stays down; a poll
    //      that sees the tunnel up (brought up by hand) clears it.
    //      run.sh: ip==3, wgq==1, nf==1.
    function stepS29() {
        switch (h.phase) {
        case "boot":
            h.phase = "wait-down";
            return true;
        case "wait-down":
            if (svc.tunnelState !== "down")
                return true;
            svc.toggle(); // down -> up; wg-quick fails
            h.phase = "wait-fail";
            return true;
        case "wait-fail":
            if (svc.desired !== "" || h.cmdAction.busy || h.cmdStatus.busy || svc.actionError === "")
                return true;
            if (svc.tunnelState !== "down") {
                return true; // the verify has not landed yet
            }
            if (svc.lastError !== Model.cmdFail(h.quickCmd("up"), 1, false)) {
                h.fail("the failed up is not on the card: '" + svc.lastError + "'");
                return false;
            }
            svc.refresh(); // the user brought it up by hand
            h.phase = "wait-up";
            return true;
        case "wait-up":
            if (h.cmdStatus.busy || svc.tunnelState !== "up")
                return true;
            if (svc.actionError !== "" || svc.lastError !== "") {
                h.fail("the confirmed up left the failed up's error: '" + svc.lastError + "'");
                return false;
            }
            if (svc._notifyKeys.action !== "") {
                h.fail("the action toast was not re-armed");
                return false;
            }
            h.pass("a failed up's error stayed while down and cleared once the tunnel was seen up");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s30: a peer that has not shaken hands yet right after the up is not
    //      stale; once the tunnel has been up past the threshold it is.
    //      run.sh: nf==1 (the handshake toast, only after the wait).
    function stepS30() {
        var msg = Model.handshakeErrorMessage([Model.shortKey("ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ=")], 135);
        switch (h.phase) {
        case "boot":
            h.phase = "wait-peers";
            return true;
        case "wait-peers":
            if (svc.peers.length === 0 || h.cmdPeers.busy)
                return true;
            if (svc.peers[0].handshake !== "never") {
                h.fail("the stub peer is not a never-handshaked one: " + svc.peers[0].handshake);
                return false;
            }
            if (svc.hasStaleHandshake || svc.handshakeError !== "" || svc.lastError !== "") {
                h.fail("a fresh up flagged the peer that has not shaken hands yet: '" + svc.lastError + "'");
                return false;
            }
            if (!(svc._upSinceMs > 0)) {
                h.fail("the up time was not recorded");
                return false;
            }
            // Pretend the tunnel came up 200 s ago; only the private field
            // can move the clock.
            svc._upSinceMs -= 200000;
            svc.refresh();
            h.phase = "wait-stale";
            return true;
        case "wait-stale":
            if (svc.handshakeError === "")
                return true;
            if (svc.handshakeError !== msg) {
                h.fail("unexpected handshake error: '" + svc.handshakeError + "'");
                return false;
            }
            h.settleT = h.ticks;
            h.phase = "settle";
            return true;
        case "settle":
            if (h.ticks - h.settleT < 5)
                return true;
            h.pass("a never-handshaked peer waited out the threshold after the up, then raised one toast");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // s31: a readable down re-arms the ip-error toast even while an outside
    //      drop stays latched. run.sh: ip==5, nf==3 (drop, error, error).
    function stepS31() {
        var dropMsg = Model.externalDropMessage("wg0");
        var readErr = Model.statusState("", "", 2, "wg0", h.ipCmd()).error;
        switch (h.phase) {
        case "boot":
            h.phase = "wait-peers";
            return true;
        case "wait-peers":
            if (svc.tunnelState !== "up" || svc.peers.length === 0 || h.cmdPeers.busy)
                return true;
            svc.refresh(); // outside drop
            h.phase = "wait-drop";
            return true;
        case "wait-drop":
            if (h.cmdStatus.busy || !svc.droppedExternally)
                return true;
            svc.refresh(); // ip error #1
            h.phase = "wait-error1";
            return true;
        case "wait-error1":
            if (h.cmdStatus.busy || svc.tunnelState !== "error")
                return true;
            if (svc.statusError !== readErr) {
                h.fail("first error is not the ip failure: '" + svc.statusError + "'");
                return false;
            }
            svc.refresh(); // readable down, drop still latched
            h.phase = "wait-down";
            return true;
        case "wait-down":
            if (h.cmdStatus.busy || svc.tunnelState !== "down")
                return true;
            if (!svc.droppedExternally || svc.statusError !== dropMsg) {
                h.fail("the latch did not survive the error poll: '" + svc.statusError + "'");
                return false;
            }
            if (svc._notifyKeys.statuserr !== "") {
                h.fail("the readable down did not re-arm the ip-error toast");
                return false;
            }
            svc.refresh(); // ip error #2, must notify again
            h.phase = "wait-error2";
            return true;
        case "wait-error2":
            if (h.cmdStatus.busy || svc.tunnelState !== "error")
                return true;
            h.settleT = h.ticks;
            h.phase = "settle";
            return true;
        case "settle":
            if (h.ticks - h.settleT < 5)
                return true;
            h.pass("a readable down re-armed the ip-error toast while the drop stayed latched");
            return false;
        }
        h.fail("unhandled phase '" + h.phase + "'");
        return false;
    }

    // Env plumbing probe for run.sh's vehicle check.
    Component.onCompleted: {
        if (h.scn === "vehicle") {
            var probe = Quickshell.env("HARNESS_PROBE");
            print("PASS vehicle: env='" + probe + "' binDir='" + h.binDir + "' scn='" + h.scn + "'");
            Qt.exit(0);
        }
    }
}
