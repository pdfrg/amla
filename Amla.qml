import "Config.js" as Config
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
    id: root

    // Injected by omarchy-shell when this plugin is summoned.
    property string omarchyPath: Quickshell.env("OMARCHY_PATH")
    property var shell: null
    property var manifest: null
    property bool opened: false
    property string filterText: ""
    property int selectedIndex: 0
    property var displayModel: []
    property string targetPlayer: "must"
    property var mustConfig: Config.mustConfig("", Quickshell.env("HOME") || "")
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property int cardWidth: 680
    readonly property real rowHeight: Style.space(44)
    readonly property int maxRows: 14
    readonly property bool emptyQuery: filterText.length === 0
    // Popup chrome, mirroring the omarchy menu card.
    readonly property color background: Color.menu.background
    readonly property color scrim: Color.menu.scrim
    readonly property real cornerRadius: Style.cornerRadius
    readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
    // Card top freezes on the first search keystroke so the card grows
    // downward instead of re-centering on every resize (menu pattern).
    property int cardTop: -1
    readonly property int centeredTop: Math.max(Style.gapsOut, Math.round((panel.height - card.height) / 2))
    readonly property int effectiveCardTop: cardTop >= 0 ? cardTop : centeredTop
    property var mockRows: [{
        "kind": "artist",
        "badge": "",
        "title": "Radiohead",
        "subtitle": "artist"
    }, {
        "kind": "album",
        "badge": "",
        "title": "OK Computer",
        "subtitle": "Radiohead · 1997"
    }, {
        "kind": "song",
        "badge": "",
        "title": "Karma Police",
        "subtitle": "OK Computer · Radiohead"
    }, {
        "kind": "genre",
        "badge": "",
        "title": "Alt Rock",
        "subtitle": "genre"
    }, {
        "kind": "year",
        "badge": "",
        "title": "1997",
        "subtitle": "year"
    }]
    readonly property string buildId: "0.3.0-config"

    function open(_payloadJson) {
        root.cardTop = -1;
        root.filterText = "";
        root.opened = true;
        root.selectedIndex = 0;
    }

    // IPC freshness probe: omarchy-shell shell call mds.amla buildInfo ""
    function buildInfo() {
        return root.buildId;
    }

    function toggleTargetPlayer() {
        root.targetPlayer = root.targetPlayer === "must" ? "cliamp" : "must";
        pluginConfigFile.setText(Config.serializePluginConfig({
            "targetPlayer": root.targetPlayer
        }));
    }

    function close() {
        root.cancel();
    }

    function cancel() {
        root.opened = false;
    }

    function ping() {
        return "ok";
    }

    function refresh() {
        return "ok";
    }

    function select(delta) {
        if (root.displayModel.length === 0)
            return ;

        var next = root.selectedIndex + delta;
        root.selectedIndex = Math.max(0, Math.min(root.displayModel.length - 1, next));
    }

    // Placeholder until the data layer lands; produces rows from the mock model.
    function rebuildDisplay() {
        var q = root.filterText.toLowerCase();
        var out = [];
        for (var i = 0; i < root.mockRows.length; i++) {
            if (q === "" || root.mockRows[i].title.toLowerCase().indexOf(q) >= 0)
                out.push(root.mockRows[i]);

        }
        root.displayModel = out;
    }

    function freezeCardTop() {
        if (panel.visible && cardTop < 0 && root.filterText.length > 0)
            cardTop = effectiveCardTop;

    }

    function activate(index) {
        // Placeholder until Dispatch.js lands.
        return null;
    }

    onFilterTextChanged: {
        root.rebuildDisplay();
        root.freezeCardTop();
    }
    onDisplayModelChanged: root.selectedIndex = 0
    Component.onCompleted: rebuildDisplay()

    // amla's XDG dirs (config/state/cache) must exist before first write.
    Process {
        id: dirSetup

        command: ["sh", "-c", "mkdir -p ~/.config/amla ~/.local/state/amla ~/.cache/amla/art"]
        running: true
    }

    FileView {
        id: mustConfigFile

        path: root.home + "/.config/must/config.toml"
        watchChanges: true
        printErrors: false
        onLoaded: root.mustConfig = Config.mustConfig(text, root.home)
    }

    FileView {
        id: pluginConfigFile

        path: root.home + "/.config/amla/config.json"
        watchChanges: true
        printErrors: false
        onLoaded: root.targetPlayer = Config.parsePluginConfig(text).targetPlayer
    }

    PanelWindow {
        id: panel

        visible: root.opened
        color: "transparent"
        WlrLayershell.namespace: "omarchy-amla"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        Rectangle {
            anchors.fill: parent
            color: root.scrim
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.cancel()
        }

        BorderSurface {
            id: card

            width: root.cardWidth
            height: Math.min(content.implicitHeight + padding * 2, panel.height - 2 * Style.gapsOut)
            radius: root.cornerRadius
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.effectiveCardTop
            color: root.background
            borderSpec: root.borderSpec
            padding: Style.space(12)

            MouseArea {
                anchors.fill: parent
                onClicked: function() {
                }
            }

            Column {
                id: content

                anchors.fill: parent
                anchors.margins: card.padding
                spacing: Style.space(8)

                Item {
                    id: keyCatcher

                    focus: true
                    Keys.priority: Keys.BeforeItem
                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Escape) {
                            if (root.filterText)
                                root.filterText = "";
                            else
                                root.cancel();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
                            root.select(-1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
                            root.select(1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_PageUp) {
                            root.select(-6);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_PageDown) {
                            root.select(6);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Home && root.displayModel.length > 0) {
                            root.selectedIndex = 0;
                            event.accepted = true;
                        } else if (event.key === Qt.Key_End && root.displayModel.length > 0) {
                            root.selectedIndex = root.displayModel.length - 1;
                            event.accepted = true;
                        } else if (event.key === Qt.Key_T && (event.modifiers & Qt.ControlModifier)) {
                            root.toggleTargetPlayer();
                            event.accepted = true;
                        } else if ((event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) && root.filterText.length > 0) {
                            root.filterText = root.filterText.slice(0, -1);
                            event.accepted = true;
                        } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
                            root.filterText += event.text;
                            event.accepted = true;
                        }
                    }
                }

                // Filter line: prompt, typed query, target badge.
                Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                        text: ">"
                        color: Color.menu.selectedText
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        id: filterDisplay

                        text: root.filterText.length > 0 ? root.filterText : "type to search"
                        color: root.filterText.length > 0 ? Color.menu.text : Color.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.italic: root.filterText.length === 0
                        elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - parent.spacing * 2 - targetBadge.width - 60
                    }

                    Rectangle {
                        id: targetBadge

                        radius: Style.cornerRadius
                        color: Color.menu.selectedBackground
                        width: badgeLabel.implicitWidth + Style.space(12)
                        height: badgeLabel.implicitHeight + Style.space(4)
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            id: badgeLabel

                            text: root.targetPlayer
                            color: Color.menu.selectedText
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            anchors.centerIn: parent
                        }

                    }

                }

                // Results.
                ListView {
                    id: resultList

                    width: parent.width
                    height: Math.min(root.maxRows * root.rowHeight, count * root.rowHeight)
                    clip: true
                    interactive: false
                    model: root.displayModel
                    currentIndex: root.selectedIndex
                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                    delegate: Rectangle {
                        required property var modelData
                        required property int index

                        width: resultList.width
                        height: root.rowHeight
                        radius: Style.cornerRadius
                        color: index === root.selectedIndex ? Color.menu.selectedBackground : (rowHover.hovered ? Style.hoverFillFor(Color.menu.text, Color.menu.selectedText, Color.urgent) : "transparent")

                        MouseArea {
                            id: rowHover

                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                root.selectedIndex = index;
                                root.freezeCardTop();
                            }
                            onDoubleClicked: root.activate(index)
                        }

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(8)
                            anchors.rightMargin: Style.space(8)
                            spacing: Style.space(10)

                            // Thumbnail slot (art lands in the thumbnails step).
                            Rectangle {
                                id: thumbBox

                                width: root.rowHeight - Style.space(10)
                                height: width
                                radius: Style.cornerRadius
                                color: Style.normalFillFor(Color.menu.text, Color.menu.selectedText)
                                anchors.verticalCenter: parent.verticalCenter

                                Text {
                                    anchors.centerIn: parent
                                    text: ""
                                    color: Color.muted
                                    font.family: Style.font.menuFamily
                                    font.pixelSize: Style.font.icon
                                }

                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - parent.spacing * 3 - thumbBox.width - badgeText.implicitWidth - starText.implicitWidth
                                spacing: 0

                                Text {
                                    text: modelData.title
                                    color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.body
                                    elide: Text.ElideRight
                                    width: parent.width
                                }

                                Text {
                                    text: modelData.subtitle
                                    color: Color.muted
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.bodySmall
                                    elide: Text.ElideRight
                                    width: parent.width
                                    visible: modelData.subtitle.length > 0
                                }

                            }

                            Text {
                                id: starText

                                text: "★"
                                color: Color.menu.selectedText
                                font.pixelSize: Style.font.body
                                visible: modelData.star === true
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                                id: badgeText

                                text: modelData.badge
                                color: Color.muted
                                font.family: Style.font.family
                                font.pixelSize: Style.font.bodySmall
                                visible: modelData.badge.length > 0
                                anchors.verticalCenter: parent.verticalCenter
                            }

                        }

                    }

                }

                Text {
                    text: root.displayModel.length === 0 && !root.emptyQuery ? "no results" : ""
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    visible: text.length > 0
                }

                // Hint bar.
                Rectangle {
                    width: parent.width
                    height: 1
                    color: Qt.alpha(Color.menu.text, 0.15)
                    visible: root.displayModel.length > 0
                }

                Text {
                    text: "enter: play   shift+enter: enqueue   ctrl+enter: play next   alt+r: random album   ctrl+t: player   esc: close"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    visible: root.displayModel.length > 0
                }

            }

        }

    }

}
