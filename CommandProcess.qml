import QtQuick
import Quickshell.Io

// One-shot command runner with a watchdog. One run at a time; every run emits
// exactly one of done or timedOut.
//
// Each start() creates its own Process, keyed by a run token, so a late exit
// from a timed-out run can never complete a later one. On timeout the child
// gets SIGTERM at once and SIGKILL after killGraceMs, and the lane is free
// again immediately.
Item {
    id: root

    readonly property bool busy: _activeCount > 0
    signal done(int exitCode, string stdout, string stderr)
    signal timedOut

    readonly property int stdoutCap: 65536
    readonly property int stderrCap: 16384
    readonly property int killGraceMs: 2000
    // Used when a caller passes a non-positive timeout, so a lane can never
    // run without a watchdog.
    readonly property int fallbackTimeoutMs: 15000

    // token -> { process, accepting, launched, graceBy }. A record lives until
    // its child exits. accepting: still the live run; graceBy: SIGKILL deadline
    // (epoch ms) once timed out, 0 otherwise.
    property var _runs: ({})
    property int _activeCount: 0
    property int _nextToken: 0
    property int _deadlineToken: -1
    property int _reapingCount: 0

    Component {
        id: processTemplate
        Process {
            id: proc
            property int runToken: 0
            property string capturedStdout: ""
            property string capturedStderr: ""

            stdout: SplitParser {
                splitMarker: ""
                onRead: function (chunk) {
                    if (root._accepting(proc.runToken) && proc.capturedStdout.length < root.stdoutCap)
                        proc.capturedStdout += String(chunk).substring(0, root.stdoutCap - proc.capturedStdout.length);
                }
            }
            stderr: SplitParser {
                splitMarker: ""
                onRead: function (chunk) {
                    if (root._accepting(proc.runToken) && proc.capturedStderr.length < root.stderrCap)
                        proc.capturedStderr += String(chunk).substring(0, root.stderrCap - proc.capturedStderr.length);
                }
            }

            onStarted: root._onStarted(proc.runToken)
            onExited: function (exitCode) {
                root._onExited(proc.runToken, exitCode);
            }
        }
    }

    Timer {
        id: deadline
        interval: root.fallbackTimeoutMs
        repeat: false
        onTriggered: root._onDeadline(root._deadlineToken)
    }

    // Sends SIGKILL to timed-out runs whose grace has elapsed. Runs only while
    // such a run exists.
    Timer {
        id: reaper
        interval: 250
        repeat: true
        running: root._reapingCount > 0
        onTriggered: root._reap()
    }

    function start(command, timeoutMs) {
        if (root.busy || !Array.isArray(command) || command.length === 0)
            return false;
        var token = ++root._nextToken;
        var p = processTemplate.createObject(root, {
            runToken: token,
            command: command
        });
        root._runs[token] = {
            process: p,
            accepting: true,
            launched: false,
            graceBy: 0
        };
        root._activeCount++;
        root._deadlineToken = token;
        deadline.interval = Number(timeoutMs) > 0 ? Number(timeoutMs) : root.fallbackTimeoutMs;
        deadline.restart();
        p.running = true;
        return true;
    }

    function _accepting(token) {
        var run = root._runs[token];
        return run !== undefined && run.accepting;
    }

    function _onStarted(token) {
        var run = root._runs[token];
        if (run !== undefined)
            run.launched = true;
    }

    function _onExited(token, exitCode) {
        var run = root._runs[token];
        if (run === undefined)
            return;
        delete root._runs[token];
        if (token === root._deadlineToken)
            deadline.stop();
        if (run.accepting) {
            root._activeCount--;
            run.accepting = false;
            root.done(exitCode, run.process.capturedStdout, run.process.capturedStderr);
        } else if (run.graceBy !== 0) {
            root._reapingCount--;
        }
        run.process.destroy();
    }

    function _onDeadline(token) {
        var run = root._runs[token];
        if (run === undefined)
            return;
        run.accepting = false;
        root._activeCount--;
        if (run.launched) {
            if (run.process.running)
                run.process.running = false; // SIGTERM
            run.graceBy = Date.now() + root.killGraceMs;
            root._reapingCount++;
        } else {
            // Never launched (e.g. missing binary): nothing to kill.
            delete root._runs[token];
            run.process.destroy();
        }
        root.timedOut();
    }

    function _reap() {
        var now = Date.now();
        for (var token in root._runs) {
            var run = root._runs[token];
            if (run.graceBy > 0 && now >= run.graceBy) {
                run.process.signal(9);
                run.graceBy = -1; // killed; still counted until it exits
            }
        }
    }
}
