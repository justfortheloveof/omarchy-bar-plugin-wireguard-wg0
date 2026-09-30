import QtQuick
import Quickshell
import "Model.js" as Model

// Host-wide singleton, loaded by the shell through the manifest's "service"
// entry point. Panels reach it with bar.shell.serviceFor(moduleName).
//
// Three command lanes, see docs/ARCHITECTURE.md:
//   status  `ip -j addr show dev wg0`, unprivileged, every poll
//   action  `sudo -n wg-quick up|down wg0`, from the toggle
//   peers   six `sudo -n wg show wg0 <field>` queries, while up
//
// Invariants:
//   - a status poll never starts while an action runs; the action's completion
//     runs its own verification poll instead;
//   - an action starts only from a confirmed up/down with both lanes idle;
//   - a peer chain runs only while up with no action in flight, and any event
//     that invalidates it bumps _peerGen so late results are dropped;
//   - a down with no plugin down pending, after this instance saw the tunnel
//     up, latches as an outside drop until the tunnel is up again (unless the
//     notifyExternalDrop setting is off);
//   - handshakeError is derived from the peers and notifies once per stale
//     episode.
Item {
    id: root

    // Directory the command binaries are resolved from. The harness points it
    // at tests/stub/. /usr/bin/env itself is never redirected.
    property string binDir: "/usr/bin/"
    property string notifyBin: "/usr/share/omarchy/bin/omarchy-notification-send"

    // Injected by the shell.
    property var manifest: null
    property string omarchyPath: ""
    readonly property string pluginId: root.manifest && root.manifest.id ? String(root.manifest.id) : ""
    readonly property string shellBin: (root.omarchyPath ? root.omarchyPath : "/usr/share/omarchy") + "/bin"

    readonly property string interfaceName: "wg0"

    // actionTimeoutMs and pollIntervalMs are properties so the harness can
    // shorten them; queryTimeoutMs is fixed at the lane's 4 s watchdog.
    property int actionTimeoutMs: 10000
    readonly property int queryTimeoutMs: 4000
    // Poll cadence comes from prefs.pollIntervalSec; a positive value here
    // overrides it (the harness uses this for its long idle interval).
    property int pollIntervalMs: 0
    readonly property int effectivePollMs: pollIntervalMs > 0 ? pollIntervalMs : prefs.pollIntervalSec * 1000

    // Published state -------------------------------------------------------

    // User settings (Model.normalizePrefs). The shell hands settings to the
    // widget only, so Panel.qml pushes them in through applyPrefs().
    property var prefs: Model.normalizePrefs({})

    // checking | up | down | error
    property string tunnelState: "checking"
    property string v4: ""
    property string v6: ""
    // Display records from Model.buildPeers. Cleared when the tunnel leaves up;
    // kept (with peerError set) when a peer query fails.
    property var peers: []
    // Direction of the in-flight toggle, "" otherwise. Owned by the action lane.
    property string desired: ""
    // A latched outside drop. tunnelState stays "down" so the toggle works; this
    // only changes colour, status text and the error card.
    property bool droppedExternally: false

    // One error per lane, each cleared by that lane's own recovery, plus:
    // actionError by a poll that confirms the failed action's target;
    // peerError by a down poll; the drop message in statusError by turning
    // notifyExternalDrop off. handshakeError is derived from the peers after
    // every peer build and is empty while the handshakeError setting is off.
    property string statusError: ""
    property string actionError: ""
    property string peerError: ""
    property string handshakeError: ""
    readonly property string lastError: Model.derivedLastError({
        actionError: root.actionError,
        statusError: root.statusError,
        peerError: root.peerError,
        handshakeError: root.handshakeError
    })

    // Status or action lane in flight. The peer lane is excluded: it is
    // invalidated by _peerGen instead of blocking the user.
    readonly property bool busy: statusCommand.busy || actionCommand.busy
    readonly property bool tunnelUp: tunnelState === "up"
    readonly property bool hasStaleHandshake: Model.stalePeerKeys(peers).length > 0

    // Internal state --------------------------------------------------------

    // Display form of the in-flight action's command, for its failure message.
    property string _actionCmd: ""
    // Direction of the last failed action while its actionError stands, ""
    // otherwise. A poll that confirms that state clears the error.
    property string _failedDirection: ""
    // Set by down() when it starts, consumed by the status poll that confirms
    // the down. Survives unreadable polls so our own down is never reported as
    // an outside drop.
    property bool _expectDown: false
    // This instance has seen the tunnel up since the last classified down.
    // In-memory only, so a freshly loaded service never reports a drop.
    property bool _sawUp: false
    // A manual refresh arrived while a status poll was running; run it
    // afterwards. A flag, not a queue: any number of refreshes make one poll.
    property bool _statusQueued: false
    // When the last status poll started (ms), for interval changes.
    property real _lastPollAt: 0
    // When this instance first saw the tunnel up since the last down (ms), 0
    // while not up. A peer that never shook hands is stale only once the
    // tunnel has been up past the threshold. Kept across an error poll, which
    // says nothing about the tunnel.
    property real _upSinceMs: 0

    readonly property var _peerChain: Model.peerChain()
    property int _peerStep: 0
    property var _peerDoc: ({})
    // A failed peer query waits here until the next status poll decides whether
    // to report it (Model.classifyPeerFailure).
    property string _pendingPeerError: ""
    // The peerError value this lane published, so a later success clears only
    // its own message.
    property string _peerPollError: ""
    // Chain generation: bumped on anything that makes an in-flight chain stale,
    // captured into _peerPollGen when a chain starts.
    property int _peerGen: 0
    property int _peerPollGen: -1

    // Last notified message per channel. A channel stays silent while its
    // message repeats, and is re-armed by its own recovery. `status` is the
    // outside drop, `statuserr` a failing ip. `handshake` notifies once per
    // episode: it stays armed-off while any peer is stale, even if the set of
    // stale peers changes.
    property var _notifyKeys: ({
            action: "",
            status: "",
            statuserr: "",
            peer: "",
            handshake: ""
        })

    // Commands --------------------------------------------------------------

    // LC_ALL=C keeps stderr in English for Model.statusState.
    function statusArgs() {
        return ["/usr/bin/env", "LC_ALL=C", binDir + "ip", "-j", "addr", "show", "dev", root.interfaceName];
    }

    function wgArgs(fieldArg) {
        return ["/usr/bin/env", "LC_ALL=C", binDir + "sudo", "-n", binDir + "wg", "show", root.interfaceName, fieldArg];
    }

    function wgQuickArgs(direction) {
        return ["/usr/bin/env", "LC_ALL=C", binDir + "sudo", "-n", binDir + "wg-quick", direction, root.interfaceName];
    }

    // Display forms quoted in error messages: the argv above without the
    // env wrapper.
    function statusCmd() {
        return binDir + "ip -j addr show dev " + root.interfaceName;
    }

    function actionCmd(direction) {
        return "sudo -n " + binDir + "wg-quick " + direction + " " + root.interfaceName;
    }

    function peerCmd(fieldArg) {
        return "sudo -n " + binDir + "wg show " + root.interfaceName + " " + fieldArg;
    }

    // Public API ------------------------------------------------------------

    function refresh() {
        if (actionCommand.busy)
            return; // the action's verification poll covers it
        if (statusCommand.busy) {
            _statusQueued = true;
            return;
        }
        _lastPollAt = Date.now();
        statusCommand.start(statusArgs(), queryTimeoutMs);
    }

    // Timer ticks never queue: a tick that finds a lane busy is skipped, so a
    // poll slower than the interval cannot make polls run back to back.
    function _pollTick() {
        if (statusCommand.busy || actionCommand.busy)
            return;
        refresh();
    }

    function toggle() {
        if (!Model.canToggle(tunnelState, root.busy))
            return;
        tunnelUp ? down() : up();
    }

    function up() {
        if (!Model.canToggle(tunnelState, root.busy))
            return;
        _startAction("up");
    }

    function down() {
        if (!Model.canToggle(tunnelState, root.busy))
            return;
        // Armed before the command runs: a failed or timed-out down is still ours.
        _expectDown = true;
        _startAction("down");
    }

    // Takes the widget's raw settings; a no-op unless a normalized value
    // changed, so N bars pushing the same settings cost one update.
    function applyPrefs(raw) {
        var next = Model.normalizePrefs(raw);
        if (Model.samePrefs(next, prefs))
            return;
        var prev = prefs;
        prefs = next;

        // Reporting turned off: an outside drop already latched becomes a
        // plain down.
        if (!next.notifyExternalDrop && droppedExternally) {
            droppedExternally = false;
            if (statusError === Model.externalDropMessage(root.interfaceName))
                statusError = "";
            _notifyKeys.status = "";
        }

        if (next.handshakeStaleAfterSec !== prev.handshakeStaleAfterSec)
            peers = Model.restalePeers(peers, Date.now(), next.handshakeStaleAfterSec, _upSinceMs);
        _evalHandshake();

        // Qt restarts a running Timer when its interval changes (without
        // triggeredOnStart). If the new interval has already passed since the
        // last poll, poll now rather than wait a full interval.
        if (next.pollIntervalSec !== prev.pollIntervalSec && pollIntervalMs <= 0
                && _lastPollAt > 0 && Date.now() - _lastPollAt >= effectivePollMs)
            _pollTick();
    }

    // Status lane -----------------------------------------------------------

    function _runQueuedStatus() {
        if (!_statusQueued)
            return;
        _statusQueued = false;
        refresh();
    }

    function _clearPeers() {
        _peerGen++;
        peers = [];
        _evalHandshake();
    }

    function _handleStatus(exitCode, stdout, stderr) {
        _applyStatus(Model.statusState(stdout, stderr, exitCode, root.interfaceName, statusCmd()));
    }

    // The watchdog is one more unreadable poll: same path as an ip error.
    function _handleStatusTimeout() {
        _applyStatus({
            state: "error",
            v4: "",
            v6: "",
            error: Model.cmdFail(statusCmd(), 0, true)
        });
    }

    // Applies one classified poll (Model.statusState shape).
    function _applyStatus(r) {
        v4 = r.v4;
        v6 = r.v6;

        // The tunnel reached what the failed action wanted: its error is moot.
        if (!actionCommand.busy && Model.actionTargetReached(_failedDirection, r.state)) {
            actionError = "";
            _failedDirection = "";
            _notifyKeys.action = "";
        }

        if (_pendingPeerError !== "") {
            if (Model.classifyPeerFailure(_pendingPeerError, r) === "report") {
                _peerPollError = _pendingPeerError;
                peerError = _pendingPeerError;
                _notify("peer", _pendingPeerError);
            }
            _pendingPeerError = "";
        }

        if (r.state === "error") {
            // Says nothing about the tunnel: drop memory and arm are kept.
            tunnelState = "error";
            statusError = r.error;
            _notify("statuserr", r.error);
            _clearPeers();
        } else if (r.state === "up") {
            tunnelState = "up";
            statusError = "";
            droppedExternally = false;
            _notifyKeys.status = "";
            _notifyKeys.statuserr = "";
            // An up seen while our own down is still running is not its verdict.
            if (!actionCommand.busy)
                _expectDown = false;
            _sawUp = true;
            if (_upSinceMs === 0)
                _upSinceMs = Date.now();
            _refreshPeers();
        } else {
            tunnelState = "down";
            statusError = "";
            _upSinceMs = 0;
            _clearPeers();
            peerError = "";
            _peerPollError = "";
            _pendingPeerError = "";
            // A down ends any stale-handshake episode.
            _notifyKeys.handshake = "";

            var drop = Model.classifyDrop("down", _sawUp, droppedExternally, _expectDown, prefs.notifyExternalDrop);
            _expectDown = false;
            if (drop !== "none")
                _sawUp = false;
            if (drop === "external") {
                droppedExternally = true;
                _notify("status", _dropToast(), _dropAction(), true);
            }

            // A readable poll: ip works again, latched or not.
            _notifyKeys.statuserr = "";
            if (droppedExternally)
                statusError = Model.externalDropMessage(root.interfaceName);
            else
                _notifyKeys.status = "";
        }
        _runQueuedStatus();
    }

    function _dropToast() {
        return Model.externalDropToast(root.interfaceName, _dropAction().length > 0);
    }

    // Argv the shell runs when the drop toast is clicked (Panel.qml bringUp).
    function _dropAction() {
        if (root.pluginId === "")
            return [];
        return [root.shellBin + "/omarchy-shell", root.pluginId, "bringUp"];
    }

    // Peer lane -------------------------------------------------------------

    function _refreshPeers() {
        if (!Model.peerStartAllowed(tunnelState, actionCommand.busy) || peersQuery.busy)
            return;
        _resetPeerChain();
        _peerPollGen = _peerGen;
        peersQuery.start(wgArgs(_peerChain[0].arg), queryTimeoutMs);
    }

    function _resetPeerChain() {
        _peerStep = 0;
        _peerDoc = {};
    }

    // A failed step is not reported directly. It is stashed and a status poll
    // decides: if the tunnel went down, the failure is dropped. An exit code of
    // 0 here means the output could not be parsed or merged.
    function _stashPeerFailure(timedOut, exitCode) {
        var step = _peerChain[_peerStep];
        var tail = !timedOut && exitCode === 0 ? ": unreadable output" : "";
        _pendingPeerError = Model.cmdFail(peerCmd(step.arg), exitCode, timedOut, tail);
        _resetPeerChain();
        _peerPollGen = -1;
        _peerGen++;
        refresh();
    }

    function _handlePeers(exitCode, stdout) {
        if (!Model.peerApplyAllowed(_peerPollGen, _peerGen, tunnelState)) {
            _resetPeerChain();
            return;
        }
        var r = Model.handlePeerStep(_peerDoc, _peerStep, exitCode, stdout);
        if (r.failed) {
            _stashPeerFailure(false, exitCode);
            return;
        }
        if (!r.done) {
            _peerStep++;
            peersQuery.start(wgArgs(_peerChain[_peerStep].arg), queryTimeoutMs);
            return;
        }
        try {
            peers = Model.buildPeers(_peerDoc, Date.now(), prefs.handshakeStaleAfterSec, _upSinceMs);
        } catch (e) {
            _stashPeerFailure(false, 0);
            return;
        }
        _resetPeerChain();
        _evalHandshake();
        if (peerError !== "" && peerError === _peerPollError) {
            peerError = "";
            _notifyKeys.peer = "";
        }
        _peerPollError = "";
        _pendingPeerError = "";
    }

    function _handlePeersTimeout() {
        if (!Model.peerApplyAllowed(_peerPollGen, _peerGen, tunnelState)) {
            _resetPeerChain();
            return;
        }
        _stashPeerFailure(true, 0);
    }

    // Handshake lane ----------------------------------------------------------

    // Derives handshakeError from the current peers. Re-arms the notification
    // only on a real recovery (peers present, none stale) or with the setting
    // off; an empty peer list (error, chain reset) says nothing either way.
    // The down branch of _applyStatus re-arms it too.
    function _evalHandshake() {
        var stale = prefs.handshakeError ? Model.stalePeerKeys(peers) : [];
        if (stale.length === 0) {
            handshakeError = "";
            if (!prefs.handshakeError || peers.length > 0)
                _notifyKeys.handshake = "";
            return;
        }
        handshakeError = Model.handshakeErrorMessage(stale, prefs.handshakeStaleAfterSec);
        if (_notifyKeys.handshake === "")
            _notify("handshake", handshakeError);
    }

    // Action lane -----------------------------------------------------------

    function _startAction(direction) {
        _peerGen++;
        desired = direction;
        _actionCmd = actionCmd(direction);
        actionCommand.start(wgQuickArgs(direction), root.actionTimeoutMs);
    }

    function _finishAction(error) {
        var direction = desired;
        desired = "";
        if (error === "") {
            actionError = "";
            _failedDirection = "";
            _notifyKeys.action = "";
        } else {
            actionError = error;
            _failedDirection = direction;
            tunnelState = "error";
            _notify("action", error);
        }
        // Verify the result with ip; this supersedes any queued refresh.
        _statusQueued = false;
        refresh();
    }

    // Notifications ---------------------------------------------------------

    // `action` is an argv the shell runs when the toast is clicked. `critical`
    // toasts stay until dismissed.
    function _notify(channel, message, action, critical) {
        if (message === _notifyKeys[channel])
            return;
        _notifyKeys[channel] = message;
        var glyph = root.tunnelUp ? Model.GLYPH_UP : Model.GLYPH_DOWN;
        var title = "WireGuard " + root.interfaceName;
        var argv = [notifyBin, "--app-name", title, "-g", glyph, "-u", critical ? "critical" : "normal", title, message];
        if (action && action.length > 0)
            argv = argv.concat(["--exec"], action);
        Quickshell.execDetached(argv);
    }

    // objectName lets tests/harness find the lanes.
    CommandProcess {
        id: statusCommand
        objectName: "statusCommand"
        onDone: function (exitCode, stdout, stderr) {
            root._handleStatus(exitCode, stdout, stderr);
        }
        onTimedOut: root._handleStatusTimeout()
    }

    CommandProcess {
        id: actionCommand
        objectName: "actionCommand"
        onDone: function (exitCode) {
            root._finishAction(exitCode === 0 ? "" : Model.cmdFail(root._actionCmd, exitCode, false));
        }
        onTimedOut: root._finishAction(Model.cmdFail(root._actionCmd, 0, true))
    }

    CommandProcess {
        id: peersQuery
        objectName: "peersQuery"
        onDone: function (exitCode, stdout) {
            root._handlePeers(exitCode, stdout);
        }
        onTimedOut: root._handlePeersTimeout()
    }

    Timer {
        id: pollTimer
        objectName: "pollTimer"
        interval: root.effectivePollMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root._pollTick()
    }
}
