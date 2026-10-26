import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property string svcState: "unknown"
    property string svcSub: ""
    property int svcPid: 0
    property string svcSince: ""
    property string errorMsg: ""
    property bool busy: false

    // Thread control
    property int svcThreads: 0          // current thread count reported by the server (0 = unknown/auto)
    property int maxThreads: 0          // 0 = server does not report it -> bar hidden
    property string cfgError: ""
    property string threadsMsg: ""
    property int pendingThreads: 0      // value sent, waiting for the server answer
    property bool dragging: false
    property int dragValue: 0
    readonly property int shownThreads: dragging ? dragValue : (pendingThreads > 0 ? pendingThreads : svcThreads)

    readonly property real gu: Kirigami.Units.gridUnit

    // Monero palette
    readonly property color cBg:     "#1A1A1A"
    readonly property color cCard:   "#262626"
    readonly property color cText:   "#FFFFFF"
    readonly property color cMuted:  "#9A9A9A"
    readonly property color cOrange: "#FF6600"
    readonly property color cGray:   "#4C4C4C"
    readonly property color cGreen:  "#2ECC71"
    readonly property color cRed:    "#E5484D"
    readonly property color cYellow: "#E9A23B"

    readonly property var stateColors: ({
        "active": cGreen, "activating": cYellow, "deactivating": cYellow,
        "reloading": cYellow, "inactive": cRed, "failed": cRed,
        "offline": cMuted, "unknown": cMuted
    })
    readonly property var stateLabels: ({
        "active": "Running", "activating": "Starting…", "deactivating": "Stopping…",
        "reloading": "Reloading…", "inactive": "Stopped", "failed": "Failed",
        "offline": "Unreachable", "unknown": "Unknown"
    })
    readonly property color dotColor: stateColors[svcState] || cMuted
    readonly property string stateLabel: stateLabels[svcState] || svcState
    readonly property bool isRunning: svcState === "active" || svcState === "activating"
    readonly property bool hasGlow: svcState !== "offline" && svcState !== "unknown"
    readonly property url logoSource: Qt.resolvedUrl("../images/monero.svg")

    toolTipMainText: "XMRig"
    toolTipSubText: errorMsg !== "" ? errorMsg : stateLabel

    function errorText(code) {
        var m = {
            "config_not_found": "config.json not found", "not_found": "config.json not found",
            "permission_denied": "No access to config.json", "invalid_json": "Invalid config.json",
            "unsupported_config": "Unsupported config.json", "invalid_file": "Invalid config.json",
            "write_failed": "Config write failed", "backup_failed": "Config backup failed",
            "edit_failed": "Config edit failed", "unreadable": "Cannot read config.json"
        }
        return m[code] || code
    }

    function call(method, path, cb, body) {
        var xhr = new XMLHttpRequest()
        xhr.timeout = body !== undefined ? 25000 : 8000   // changing threads restarts the service
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (xhr.status === 200) {
                try { cb(null, JSON.parse(xhr.responseText)) }
                catch (e) { cb("Invalid response", null) }
            } else if (xhr.status === 0) {
                cb("Server unreachable", null)
            } else if (xhr.status === 401) {
                cb("Invalid token", null)
            } else {
                var msg = "HTTP " + xhr.status
                try { var e = JSON.parse(xhr.responseText); if (e.error) msg = root.errorText(e.error) } catch (x) {}
                cb(msg, null)
            }
        }
        var base = Plasmoid.configuration.serverUrl.replace(/\/+$/, "")
        xhr.open(method, base + path)
        xhr.setRequestHeader("Authorization", "Bearer " + Plasmoid.configuration.token)
        if (body !== undefined) {
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.send(JSON.stringify(body))
        } else {
            xhr.send()
        }
    }

    function apply(err, data) {
        busy = false
        if (err) {
            errorMsg = err
            svcState = "offline"
            svcSub = ""
            svcPid = 0
            svcSince = ""
            svcThreads = 0          // keep maxThreads so the bar does not jump
            return
        }
        errorMsg = ""
        svcState = data.state
        svcSub = data.substate
        svcPid = data.pid
        svcSince = data.since
        svcThreads = (typeof data.threads === "number") ? data.threads : 0
        maxThreads = (typeof data.max_threads === "number") ? data.max_threads : 0
        cfgError = data.config_error ? errorText(data.config_error) : ""
    }

    function setThreads(n) {
        threadsMsg = ""
        pendingThreads = n
        busy = true
        call("POST", "/threads", applyThreads, { "threads": n })
    }

    function applyThreads(err, data) {
        pendingThreads = 0
        if (err === "Server unreachable" || err === "Invalid token") {
            apply(err, null)
        } else if (err) {
            busy = false
            threadsMsg = err
            msgTimer.restart()
        } else {
            apply(null, data)
        }
    }

    function formatSince(t) {
        var m = /(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})/.exec(t)
        return m ? m[1] + " " + m[2] : t
    }

    function refresh() { call("GET", "/status", apply) }
    function act(name) { busy = true; call("POST", "/" + name, apply) }

    Timer {
        id: msgTimer
        interval: 6000
        onTriggered: root.threadsMsg = ""
    }

    Timer {
        interval: Math.max(2, Plasmoid.configuration.interval) * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    compactRepresentation: Item {
        Image {
            anchors.fill: parent
            source: root.logoSource
            sourceSize: Qt.size(128, 128)
            fillMode: Image.PreserveAspectFit
            smooth: true
            opacity: root.hasGlow ? 1.0 : 0.5
        }
        Rectangle {
            width: Math.max(6, parent.height * 0.3)
            height: width
            radius: width / 2
            color: root.dotColor
            border.color: Kirigami.Theme.backgroundColor
            border.width: 1
            anchors.right: parent.right
            anchors.bottom: parent.bottom
        }
        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }
    }

    fullRepresentation: Rectangle {
        id: panel
        color: root.cBg

        readonly property string pos: Plasmoid.configuration.layoutPosition
        readonly property bool horizontal: pos === "left" || pos === "right"
        readonly property bool reversed: pos === "left" || pos === "top"

        // Small minimum, no maximum: freely resizable
        Layout.preferredWidth: root.gu * (horizontal ? 24 : 16)
        Layout.preferredHeight: root.gu * (horizontal ? 15 : 24)
        Layout.minimumWidth: root.gu * (horizontal ? 14 : 9)
        Layout.minimumHeight: root.gu * (horizontal ? 8 : 11)

        // Content scale follows the available size
        readonly property real k: Math.max(0.7, Math.min(3.0, Math.min(
            width  / (root.gu * (horizontal ? 24 : 16)),
            height / (root.gu * (horizontal ? 15 : 24)))))
        readonly property bool showThreads: root.maxThreads > 0
            && height >= root.gu * (horizontal ? 9 : 13)
        readonly property bool showInfo: height >= root.gu * (horizontal ? 12 : 17)
            && (root.svcSub !== "" || root.svcPid > 0)

        component InfoRow: RowLayout {
            property string label
            property string value
            Layout.fillWidth: true
            spacing: root.gu * 0.5
            visible: value !== ""
            Text {
                text: parent.label
                color: root.cMuted
                font.pixelSize: Math.round(12 * panel.k)
            }
            Text {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                horizontalAlignment: Text.AlignRight
                text: parent.value
                color: root.cText
                font.pixelSize: Math.round(12 * panel.k)
                elide: Text.ElideRight
            }
        }

        GridLayout {
            anchors.fill: parent
            anchors.margins: root.gu * 0.9 * panel.k
            columns: panel.horizontal ? 2 : 1
            rowSpacing: root.gu * 0.6 * panel.k
            columnSpacing: root.gu * 0.9 * panel.k

            // Logo + status (takes all the free space)
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.row: panel.horizontal ? 0 : (panel.reversed ? 1 : 0)
                Layout.column: panel.horizontal ? (panel.reversed ? 1 : 0) : 0
                spacing: root.gu * 0.4 * panel.k

                Item {
                    id: logoArea
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: root.gu * 2
                    readonly property real sz: Math.min(width, height) / 1.7

                    // Static glow: stacked translucent circles (no animation, no shader)
                    Repeater {
                        model: root.hasGlow ? 8 : 0
                        Rectangle {
                            width: logoArea.sz * (1.0 + index * 0.09)
                            height: width
                            radius: width / 2
                            anchors.centerIn: parent
                            color: Qt.rgba(root.dotColor.r, root.dotColor.g, root.dotColor.b, 0.05)
                        }
                    }
                    Image {
                        anchors.centerIn: parent
                        width: logoArea.sz
                        height: width
                        source: root.logoSource
                        sourceSize: Qt.size(256, 256)
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                        opacity: root.hasGlow ? 1.0 : 0.5
                    }

                    // Refresh icon, top-right of the logo area
                    Kirigami.Icon {
                        x: panel.pos === "right" ? 0 : logoArea.width - width
                        y: 0
                        source: "view-refresh"
                        isMask: true
                        color: refreshArea.containsMouse ? root.cText : root.cMuted
                        width: Math.round(Kirigami.Units.iconSizes.smallMedium * panel.k)
                        height: width
                        MouseArea {
                            id: refreshArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.refresh()
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: root.stateLabel
                    color: root.dotColor
                    font.pixelSize: Math.round(22 * panel.k)
                    font.bold: true
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: root.errorMsg !== ""
                    text: root.errorMsg
                    color: root.cMuted
                    font.pixelSize: Math.round(13 * panel.k)
                }
            }

            // Info card + Start/Stop button
            ColumnLayout {
                Layout.fillWidth: !panel.horizontal
                Layout.fillHeight: false
                Layout.alignment: panel.horizontal ? Qt.AlignVCenter : Qt.AlignTop
                Layout.preferredWidth: panel.horizontal ? panel.width * 0.42 : -1
                Layout.minimumWidth: 0
                Layout.row: panel.horizontal ? 0 : (panel.reversed ? 0 : 1)
                Layout.column: panel.horizontal ? (panel.reversed ? 0 : 1) : 0
                spacing: root.gu * 0.6 * panel.k

                // Thread control: one notch per logical CPU, orange = threads in use
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: panel.showThreads
                    spacing: root.gu * 0.3 * panel.k

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: root.gu * 0.5
                        Text {
                            text: "Threads"
                            color: root.cMuted
                            font.pixelSize: Math.round(12 * panel.k)
                        }
                        Text {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                            font.pixelSize: Math.round(12 * panel.k)
                            color: root.threadsMsg !== "" ? root.cRed : root.cText
                            text: root.threadsMsg !== "" ? root.threadsMsg
                                  : root.cfgError !== "" ? root.cfgError
                                  : (root.shownThreads > 0 ? root.shownThreads : "—") + " / " + root.maxThreads
                        }
                    }

                    Item {
                        id: threadBar
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.max(10, root.gu * 1.1 * panel.k)

                        readonly property bool usable: !root.busy && root.cfgError === ""
                            && root.svcState !== "offline" && root.svcState !== "unknown"
                        readonly property real gap: (width / Math.max(1, root.maxThreads)) > 7 ? 2 : 0
                        opacity: usable ? 1.0 : 0.45

                        Row {
                            anchors.fill: parent
                            spacing: threadBar.gap
                            Repeater {
                                model: root.maxThreads
                                Rectangle {
                                    width: Math.max(1, (threadBar.width - threadBar.gap * (root.maxThreads - 1)) / root.maxThreads)
                                    height: threadBar.height
                                    radius: Math.min(3, width / 2)
                                    color: index < root.shownThreads ? root.cOrange : "#333333"
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: threadBar.usable
                            cursorShape: Qt.PointingHandCursor
                            function valueAt(x) {
                                return Math.max(1, Math.min(root.maxThreads,
                                                Math.floor(x / width * root.maxThreads) + 1))
                            }
                            onPressed: (m) => { root.dragging = true; root.dragValue = valueAt(m.x) }
                            onPositionChanged: (m) => { if (pressed) root.dragValue = valueAt(m.x) }
                            onReleased: {
                                root.dragging = false
                                if (root.dragValue !== root.svcThreads) root.setThreads(root.dragValue)
                            }
                            onCanceled: root.dragging = false
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    color: root.cCard
                    radius: 8
                    visible: panel.showInfo
                    implicitHeight: infoCol.implicitHeight + root.gu * 1.2 * panel.k

                    ColumnLayout {
                        id: infoCol
                        anchors.fill: parent
                        anchors.margins: root.gu * 0.6 * panel.k
                        spacing: root.gu * 0.5 * panel.k

                        InfoRow { label: "State"; value: root.svcSub }
                        InfoRow { label: "PID";   value: root.svcPid > 0 ? String(root.svcPid) : "" }
                        InfoRow { label: "Since"; value: root.svcState === "active" ? root.formatSince(root.svcSince) : "" }
                    }
                }

                Rectangle {
                    id: mainBtn
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.gu * 2.4 * panel.k
                    radius: 8

                    readonly property bool usable: !root.busy && root.svcState !== "offline" && root.svcState !== "unknown"

                    color: root.isRunning
                           ? (btnArea.containsMouse ? "#5A5A5A" : root.cGray)
                           : (btnArea.containsMouse ? "#FF7A26" : root.cOrange)
                    opacity: usable ? 1.0 : 0.45

                    Text {
                        anchors.centerIn: parent
                        text: root.busy ? "Please wait…" : (root.isRunning ? "Stop" : "Start")
                        color: root.cText
                        font.pixelSize: Math.round(15 * panel.k)
                        font.bold: true
                    }
                    MouseArea {
                        id: btnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: mainBtn.usable
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.act(root.isRunning ? "stop" : "start")
                    }
                }
            }
        }
    }
}
