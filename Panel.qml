import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
    id: root
    // Must match manifest.json "id". Panels get no manifest, so this is the
    // one place the widget side spells it (the first-party panels do the same).
    readonly property string pluginId: "io.github.justfortheloveof.wireguard-wg0"
    moduleName: pluginId
    ipcTarget: pluginId
    manageIpc: false

    // The shared Service.qml instance. `bar` is injected after load and the
    // service may appear later, so resolve lazily and retry until found.
    property var wg: null

    function resolveWg() {
        if (root.wg !== null)
            return;
        if (!bar || !bar.shell || typeof bar.shell.serviceFor !== "function")
            return;
        var s = bar.shell.serviceFor(moduleName);
        if (s !== null && s !== undefined)
            root.wg = s;
    }

    onBarChanged: resolveWg()
    Component.onCompleted: resolveWg()

    Timer {
        interval: 500
        repeat: true
        running: root.bar !== null && root.wg === null
        onTriggered: root.resolveWg()
    }

    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property color urgent: bar ? bar.urgent : Color.urgent
    readonly property color dim: Qt.darker(foreground, 1.4)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
    // The tunnel itself is in trouble; drives the status row.
    readonly property bool tunnelAlarmed: root.wg !== null && (root.wg.tunnelState === "error" || root.wg.droppedExternally)
    // Red whenever the error card is, whatever lane raised it; drives the icons.
    // A superset of tunnelAlarmed, which the status row uses on its own.
    readonly property bool alarmed: root.wg !== null && (root.wg.tunnelState === "error" || root.wg.lastError !== "")
    readonly property color stateColor: alarmed ? urgent : (root.wg !== null && root.wg.tunnelUp ? foreground : dim)
    // Shape says up or not; colour separates the other states.
    readonly property string stateGlyph: root.wg !== null && root.wg.tunnelUp ? Model.GLYPH_UP : Model.GLYPH_DOWN
    readonly property string heroMeta: Model.heroMeta(root.wg ? root.wg.tunnelState : "checking")
    // 1.55 is the kit's dim factor for bar icons.
    readonly property color barDim: Qt.darker(barForeground, 1.55)
    readonly property color barIconColor: alarmed ? urgent : (root.wg !== null && root.wg.tunnelUp ? barForeground : barDim)
    readonly property string toggleHint: root.wg !== null && root.wg.tunnelUp ? "Turn the WireGuard tunnel off" : "Turn the WireGuard tunnel on"

    // Settings ----------------------------------------------------------------

    // Stored inline on this widget's bar entry in shell.json; the shell sets
    // `settings` on load and whenever the entry changes.
    readonly property var prefs: Model.normalizePrefs(settings)

    // The service gets no settings of its own; push ours. applyPrefs ignores
    // an unchanged push, so every bar instance can call it.
    function pushPrefs() {
        if (root.wg)
            root.wg.applyPrefs(settings);
    }
    onPrefsChanged: pushPrefs()
    onWgChanged: pushPrefs()

    // Merge into the existing entry so unrelated keys survive, then persist.
    function savePref(key, value) {
        var next = {};
        for (var k in settings)
            next[k] = settings[k];
        next[key] = value;
        settings = next;
        if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
            bar.shell.updateEntryInline(moduleName, next);
    }

    // Body below the hero: "details" (status, peers) or "settings".
    property string view: "details"
    readonly property bool settingsOpen: view === "settings"

    function toggleSettings() {
        finishNumberEdit(true);
        view = settingsOpen ? "details" : "settings";
        settingsIndex = -1;
        if (scrollArea.contentItem)
            scrollArea.contentItem.contentY = 0;
    }

    // Header cursor: 0 refresh, 1 settings, 2 tunnel switch.
    property int headerIndex: 2
    property bool cursorActive: false
    // Settings rows cursor: -1 means the cursor is in the header.
    property int settingsIndex: -1
    readonly property int settingsCount: 4
    readonly property bool headerHasCursor: cursorActive && settingsIndex < 0
    readonly property bool refreshHasCursor: headerHasCursor && headerIndex === 0
    readonly property bool gearHasCursor: headerHasCursor && headerIndex === 1
    readonly property bool toggleHasCursor: headerHasCursor && headerIndex === 2

    function setHeaderCursor(i) {
        cursorActive = true;
        settingsIndex = -1;
        headerIndex = i;
    }
    function setSettingsCursor(i) {
        cursorActive = true;
        settingsIndex = i;
    }
    function selectHeaderByDelta(d) {
        headerIndex = Math.max(0, Math.min(2, headerIndex + d));
    }
    function activateHeader() {
        if (headerIndex === 0) {
            if (root.wg)
                root.wg.refresh();
        } else if (headerIndex === 1) {
            toggleSettings();
        } else {
            if (root.wg)
                root.wg.toggle();
        }
    }
    function activateSetting(i) {
        if (i === 0)
            savePref("notifyExternalDrop", !prefs.notifyExternalDrop);
        else if (i === 1)
            savePref("handshakeError", !prefs.handshakeError);
        else if (i === 2)
            thresholdField.begin();
        else if (i === 3)
            pollField.begin();
    }

    // A number field owns the keyboard while it has focus
    // (PanelKeyCatcher.blocked); see PrefNumberField.
    readonly property bool editingNumber: thresholdField.editing || pollField.editing

    function finishNumberEdit(commit) {
        thresholdField.finish(commit);
        pollField.finish(commit);
    }

    // The value is passed as an argument, never through a shell.
    function copyToClipboard(value) {
        if (!value)
            return;
        Quickshell.execDetached(["/usr/bin/wl-copy", "--", String(value)]);
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    onOpenedChanged: if (!opened) {
        finishNumberEdit(true);
    } else {
        cursorActive = false;
        headerIndex = 2;
        settingsIndex = -1;
        view = "details";
        if (scrollArea.contentItem)
            scrollArea.contentItem.contentY = 0;
        if (root.wg)
            root.wg.refresh();
        Qt.callLater(function () {
            keyCatcher.forceActiveFocus();
        });
    }

    IpcHandler {
        target: root.pluginId

        function open() {
            root.open();
        }
        function close() {
            root.close();
        }
        function show() {
            root.open();
        }
        function hide() {
            root.close();
        }
        function toggle() {
            root.toggle();
        }
        // Click action of the outside-drop toast. up() itself refuses unless the
        // tunnel is confirmed down and idle, so a stale toast is a no-op.
        function bringUp() {
            if (root.wg && !root.wg.tunnelUp)
                root.wg.up();
        }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        slotSize: Style.bar.iconSlot
        text: root.stateGlyph
        useActiveColor: false
        foreground: root.barIconColor
        onPressed: function (b) {
            if (b === Qt.LeftButton)
                root.toggle();
        }
    }

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(380))
        contentHeight: panel.fittedContentHeight(column.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: root.editingNumber
            onActivateRequested: {
                if (!root.cursorActive)
                    return;
                if (root.settingsIndex >= 0)
                    root.activateSetting(root.settingsIndex);
                else
                    root.activateHeader();
            }
            // Esc backs out of settings first, then closes.
            onCloseRequested: root.settingsOpen ? root.toggleSettings() : root.close()
            onTabRequested: function (direction) {
                root.switchPanel(direction);
            }
            onTextKey: function (t) {
                var k = t.toLowerCase();
                if (k === "r") {
                    if (root.wg)
                        root.wg.refresh();
                } else if (k === "t") {
                    if (root.wg)
                        root.wg.toggle();
                } else if (k === "s" || k === "c") {
                    root.toggleSettings();
                }
            }
            onMoveRequested: function (dx, dy) {
                if (!root.cursorActive) {
                    root.cursorActive = true;
                    return;
                }
                if (dx !== 0) {
                    if (root.settingsIndex < 0)
                        root.selectHeaderByDelta(dx);
                    return;
                }
                if (dy === 0)
                    return;
                // Settings: the cursor walks header -> rows and back.
                if (root.settingsOpen) {
                    root.settingsIndex = Math.max(-1, Math.min(root.settingsCount - 1, root.settingsIndex + dy));
                    return;
                }
                var flick = scrollArea.contentItem;
                if (!flick || flick.contentY === undefined)
                    return;
                flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + dy * Style.space(48)));
            }

            ScrollView {
                id: scrollArea
                anchors.fill: parent
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: column.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                Binding {
                    target: scrollArea.contentItem
                    property: "interactive"
                    value: column.implicitHeight > scrollArea.height
                }

                Column {
                    id: column
                    width: scrollArea.availableWidth
                    // The first-party panels space their body sections at 12.
                    spacing: Style.space(12)

                    PanelHero {
                        width: parent.width
                        title: "WireGuard Tunnel"
                        meta: root.heroMeta
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        // Dimmed only while plainly down or checking; every error is full strength.
                        iconOpacity: root.alarmed || (root.wg !== null && root.wg.tunnelUp) ? 1.0 : 0.5
                        iconComponent: Component {
                            TunnelMark {
                                iconSize: Style.font.display
                                color: root.stateColor
                            }
                        }
                        trailingControl: Component {
                            RowLayout {
                                spacing: Style.space(8)

                                // Sized like the network panel's speed-test button. The
                                // disabled look is painted by hand: `enabled` only blocks input.
                                Button {
                                    iconText: "󰁪"
                                    tooltipText: "Refresh data"
                                    foreground: root.wg !== null && root.wg.busy ? Qt.darker(root.foreground, 2.0) : root.foreground
                                    fontFamily: root.fontFamily
                                    iconSize: Style.font.subtitle * 1.5
                                    horizontalPadding: Style.space(5)
                                    verticalPadding: Style.space(2)
                                    enabled: !(root.wg !== null && root.wg.busy)
                                    hasCursor: root.refreshHasCursor
                                    Layout.alignment: Qt.AlignVCenter
                                    onHovered: function (h) {
                                        if (h)
                                            root.setHeaderCursor(0);
                                    }
                                    onClicked: if (root.wg)
                                        root.wg.refresh()
                                }

                                Button {
                                    iconText: "󰒓"
                                    tooltipText: root.settingsOpen ? "Back to details" : "Settings"
                                    foreground: root.foreground
                                    fontFamily: root.fontFamily
                                    iconSize: Style.font.subtitle * 1.5
                                    horizontalPadding: Style.space(5)
                                    verticalPadding: Style.space(2)
                                    active: root.settingsOpen
                                    hasCursor: root.gearHasCursor
                                    Layout.alignment: Qt.AlignVCenter
                                    onHovered: function (h) {
                                        if (h)
                                            root.setHeaderCursor(1);
                                    }
                                    onClicked: root.toggleSettings()
                                }

                                ToggleSwitch {
                                    id: powerSwitch
                                    checked: root.wg !== null && root.wg.tunnelUp
                                    busy: root.wg !== null && root.wg.busy
                                    foreground: root.foreground
                                    hasCursor: root.toggleHasCursor
                                    // Only from a confirmed up/down. `busy` is left to the
                                    // switch's spinner, so a mid-poll switch still looks live.
                                    interactive: root.wg !== null && Model.canToggle(root.wg.tunnelState, false)
                                    onHovered: function (h) {
                                        if (h)
                                            root.setHeaderCursor(2);
                                    }
                                    onToggled: if (root.wg)
                                        root.wg.toggle()

                                    PanelToolTip {
                                        visible: powerSwitch.containsMouse
                                        text: root.toggleHint
                                        fontFamily: root.fontFamily
                                    }
                                }
                            }
                        }
                    }

                    // Details view: error card, status and peers.
                    Column {
                        width: parent.width
                        spacing: Style.space(12)
                        visible: !root.settingsOpen

                        // Highest-priority error (Model.derivedLastError), hidden when
                        // empty. Styled like the network panel's status card, but sized
                        // to the wrapped text.
                        BorderSurface {
                            visible: root.wg !== null && root.wg.lastError !== ""
                            width: parent.width
                            implicitHeight: errText.implicitHeight + Style.spacing.controlHeight
                            radius: Style.cornerRadius
                            color: Style.normalFillFor(root.foreground)
                            borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

                            Text {
                                id: errText
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: Style.spacing.controlHeight / 2
                                textFormat: Text.PlainText
                                text: root.wg ? root.wg.lastError : ""
                                wrapMode: Text.Wrap
                                color: root.urgent
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }
                        }

                        // Four columns: label, value, label, value. Always mounted so
                        // the first poll fills it in place.
                        GridLayout {
                            width: parent.width
                            columns: 4
                            columnSpacing: Style.space(20)
                            rowSpacing: Style.spacing.labelGap

                            StatLabel {
                                text: "Status"
                            }
                            StatValue {
                                Layout.columnSpan: 3
                                value: Model.statusRow(root.wg ? root.wg.tunnelState : "checking", root.wg !== null && root.wg.busy, root.wg ? root.wg.desired : "", root.wg !== null && root.wg.droppedExternally)
                                valueColor: root.tunnelAlarmed ? root.urgent : root.foreground
                            }
                            StatLabel {
                                text: "IP Address"
                            }
                            StatValue {
                                Layout.columnSpan: 3
                                value: Model.ipDisplay(root.wg ? root.wg.v4 : "", root.wg ? root.wg.v6 : "")
                                copyable: true
                                tooltipText: "Copy IP"
                            }
                        }

                        PanelSeparator {
                            foreground: root.foreground
                            visible: root.wg !== null && root.wg.peers.length > 0
                        }

                        Repeater {
                            model: root.wg ? root.wg.peers : []

                            Column {
                                width: parent.width
                                spacing: Style.space(10)

                                PeerHeader {
                                    text: "PEER: " + modelData.shortKey
                                    publicKey: modelData.publicKey
                                    foreground: root.foreground
                                    fontFamily: root.fontFamily
                                }

                                GridLayout {
                                    width: parent.width
                                    columns: 4
                                    columnSpacing: Style.space(20)
                                    rowSpacing: Style.spacing.labelGap

                                    // Variable-length values span the row; short ones pair up.
                                    StatLabel {
                                        text: "Endpoint"
                                    }
                                    StatValue {
                                        Layout.columnSpan: 3
                                        value: modelData.endpoint
                                        copyable: true
                                        tooltipText: "Copy endpoint"
                                    }

                                    StatLabel {
                                        text: "AllowedIPs"
                                    }
                                    StatValue {
                                        Layout.columnSpan: 3
                                        value: modelData.allowedIps
                                        copyable: true
                                        tooltipText: "Copy allowed IPs"
                                    }

                                    StatLabel {
                                        text: "Handshake"
                                    }
                                    StatValue {
                                        value: modelData.handshake
                                        valueColor: modelData.handshakeStale && root.prefs.handshakeError ? root.urgent : root.foreground
                                    }
                                    StatLabel {
                                        text: "Keepalive"
                                    }
                                    StatValue {
                                        value: modelData.keepalive
                                    }

                                    StatLabel {
                                        text: "Downloaded"
                                    }
                                    StatValue {
                                        value: modelData.downloaded
                                    }
                                    StatLabel {
                                        text: "Uploaded"
                                    }
                                    StatValue {
                                        value: modelData.uploaded
                                    }
                                }
                            }
                        }
                    }

                    // Settings view. Every change is saved at once (savePref).
                    Column {
                        width: parent.width
                        spacing: Style.space(8)
                        visible: root.settingsOpen

                        PanelSectionHeader {
                            text: "SETTINGS"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        SettingRow {
                            label: "Error and notify on external down"
                            description: "When something other than this plugin takes wg0 down."
                            index: 0
                            onClicked: root.activateSetting(0)

                            ToggleSwitch {
                                checked: root.prefs.notifyExternalDrop
                                foreground: root.foreground
                                // The row owns the click.
                                interactive: false
                            }
                        }

                        SettingRow {
                            label: "Error on expired handshake"
                            description: "When a peer's last handshake is older than the threshold below."
                            index: 1
                            onClicked: root.activateSetting(1)

                            ToggleSwitch {
                                checked: root.prefs.handshakeError
                                foreground: root.foreground
                                interactive: false
                            }
                        }

                        // Only matters while the handshake error is on.
                        SettingRow {
                            label: "Expired handshake threshold"
                            description: "Seconds, " + Model.HANDSHAKE_MIN_SEC + " or more. Enter to edit."
                            index: 2
                            opacity: root.prefs.handshakeError ? 1.0 : 0.5

                            PrefNumberField {
                                id: thresholdField
                                prefKey: "handshakeStaleAfterSec"
                                rowIndex: 2
                                from: Model.HANDSHAKE_MIN_SEC
                                to: Model.HANDSHAKE_MAX_SEC
                                stepSize: 15
                            }
                        }

                        SettingRow {
                            label: "Poll interval"
                            description: "Seconds between checks, " + Model.POLL_MIN_SEC + " or more. Enter to edit."
                            index: 3

                            PrefNumberField {
                                id: pollField
                                prefKey: "pollIntervalSec"
                                rowIndex: 3
                                from: Model.POLL_MIN_SEC
                                to: Model.POLL_MAX_SEC
                                stepSize: 1
                            }
                        }
                    }
                }
            }
        }
    }

    // Shared label column width, so every grid lines up as one table. Measured
    // from the widest label so it follows the theme font.
    Text {
        id: labelRuler
        visible: false
        textFormat: Text.PlainText
        text: "Downloaded"
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
    }
    readonly property real labelColumnWidth: labelRuler.implicitWidth

    // A settings row laid out like the kit's Toggle (fill, border, cursor),
    // with the title in the network panel's list font: body size, regular
    // weight. The trailing control (switch or field) goes in as a child.
    component SettingRow: BorderSurface {
        id: srow
        property string label: ""
        property string description: ""
        property int index: -1
        default property alias trailing: trailingSlot.data
        readonly property bool hot: (root.cursorActive && root.settingsIndex === srow.index) || rowHover.hovered

        signal clicked

        width: parent ? parent.width : 0
        implicitHeight: Math.max(54, Math.max(rowText.implicitHeight, trailingSlot.childrenRect.height) + Style.spacing.huge)
        radius: Style.cornerRadius
        color: Style.controlFill(false, hot, root.foreground, Color.accent)
        borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.foreground, Color.accent)

        // Declared before the trailing slot so the field still takes its own clicks.
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: srow.clicked()
        }

        HoverHandler {
            id: rowHover
            onHoveredChanged: if (hovered)
                root.setSettingsCursor(srow.index)
        }

        Column {
            id: rowText
            anchors.left: parent.left
            anchors.right: trailingSlot.left
            anchors.leftMargin: srow.borderLeft + Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: srow.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: srow.description
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
            }
        }

        Item {
            id: trailingSlot
            anchors.right: parent.right
            anchors.rightMargin: srow.borderRight + Style.spacing.rowPaddingX
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
    }

    // An integer setting. The arrows save each step; typed text is committed
    // by Return or by leaving the field, and Esc reverts. Out-of-range input
    // is clamped, anything else keeps the stored value.
    component PrefNumberField: NumberField {
        id: pnf
        required property string prefKey
        required property int rowIndex
        readonly property bool editing: pnf.field.activeFocus
        property bool _finishing: false

        // Room for "86400"; the kit default crowds out the label.
        fieldWidth: Style.space(90)
        value: root.prefs[pnf.prefKey]
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        hasCursor: root.cursorActive && root.settingsIndex === pnf.rowIndex

        onEditingChanged: if (!editing && !_finishing)
            commit(true)
        onModified: function (v) {
            if (!pnf.editing && v !== root.prefs[pnf.prefKey])
                root.savePref(pnf.prefKey, v);
        }
        onHovered: function (h) {
            if (h)
                root.setSettingsCursor(pnf.rowIndex);
        }
        // Reached when the field lets the key through (TextInput does not
        // accept Return or Esc).
        Keys.onReturnPressed: pnf.finish(true)
        Keys.onEnterPressed: pnf.finish(true)
        Keys.onEscapePressed: pnf.finish(false)

        function begin() {
            root.setSettingsCursor(pnf.rowIndex);
            pnf.field.forceActiveFocus();
            pnf.field.contentItem.selectAll();
        }

        function commit(save) {
            var spin = pnf.field;
            var input = spin.contentItem;
            var stored = root.prefs[pnf.prefKey];
            if (save) {
                var typed = Model.intPref(String(input.text).trim(), stored, pnf.from, pnf.to);
                if (typed !== stored)
                    root.savePref(pnf.prefKey, typed);
            }
            // The SpinBox's displayText follows the typed text, and typing
            // replaced the field's text binding. Reset both to the stored value.
            input.text = spin.textFromValue(root.prefs[pnf.prefKey], spin.locale);
            input.text = Qt.binding(function () {
                return pnf.field.displayText;
            });
        }

        function finish(save) {
            if (!pnf.editing)
                return;
            pnf._finishing = true;
            pnf.commit(save);
            keyCatcher.forceActiveFocus();
            pnf._finishing = false;
        }
    }

    // Shows the short key; clicking copies the full one.
    component PeerHeader: PanelSectionHeader {
        id: header
        required property string publicKey

        MouseArea {
            id: headerMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.copyToClipboard(header.publicKey)
        }

        PanelToolTip {
            visible: headerMouse.containsMouse
            text: "Copy peer key"
            fontFamily: root.fontFamily
        }
    }

    component StatLabel: Text {
        textFormat: Text.PlainText
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        Layout.minimumWidth: root.labelColumnWidth
        Layout.preferredWidth: root.labelColumnWidth
        Layout.maximumWidth: root.labelColumnWidth
    }

    // Right-aligned value. Placeholders ("", "--", wg's "(none)") are never copyable.
    component StatValue: Text {
        id: stat
        required property string value
        property color valueColor: root.foreground
        property bool copyable: false
        property string tooltipText: "Copy to clipboard"

        textFormat: Text.PlainText
        text: stat.value
        color: stat.valueColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        Layout.fillWidth: true

        readonly property bool empty: text === "" || text === "--" || text === "(none)"

        // Covers only the painted (right-aligned, possibly elided) text, not
        // the whole fill-width column.
        MouseArea {
            id: statMouse
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Math.min(stat.width, stat.contentWidth)
            enabled: stat.copyable && !stat.empty
            hoverEnabled: enabled
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.copyToClipboard(stat.text)

            // Parented to the hit area so ToolTip centers over the text.
            PanelToolTip {
                visible: statMouse.enabled && statMouse.containsMouse
                text: stat.tooltipText
                fontFamily: root.fontFamily
            }
        }
    }

    component TunnelMark: Text {
        id: mark

        property real iconSize: Style.font.icon

        textFormat: Text.PlainText
        text: root.stateGlyph
        font.family: root.fontFamily
        font.pixelSize: mark.iconSize
        horizontalAlignment: Text.AlignHCenter
        renderType: Text.NativeRendering
    }
}
