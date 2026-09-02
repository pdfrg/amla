import QtQuick
import Quickshell
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
    readonly property int cardWidth: 680
    readonly property real rowHeight: Style.space(36)

    function open(_payloadJson) {
        root.opened = true;
        root.selectedIndex = 0;
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

    function select(delta) {
        if (root.displayModel.length === 0)
            return ;

        var next = root.selectedIndex + delta;
        root.selectedIndex = Math.max(0, Math.min(root.displayModel.length - 1, next));
    }

    onDisplayModelChanged: root.selectedIndex = 0
    Component.onCompleted: {
        root.displayModel = [{
            "title": "skeleton row one",
            "kind": "song"
        }, {
            "title": "skeleton row two",
            "kind": "album"
        }, {
            "title": "skeleton row three",
            "kind": "artist"
        }];
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
            color: Color.menu.scrim
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.cancel()
        }

        BorderSurface {
            id: card

            width: root.cardWidth
            height: Math.min(content.implicitHeight + Style.space(24), panel.height - 2 * Style.gapsOut)
            radius: Style.cornerRadius
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            color: Color.menu.background
            borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
            padding: Style.space(12)

            MouseArea {
                anchors.fill: parent
                onClicked: function() {
                }
            }

            Column {
                id: content

                anchors.fill: parent
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
                        } else if (event.key === Qt.Key_Up) {
                            root.select(-1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down) {
                            root.select(1);
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

                Row {
                    spacing: Style.space(8)

                    Text {
                        text: ">"
                        color: Color.menu.selectedText
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: root.filterText.length > 0 ? root.filterText : "type to search"
                        color: root.filterText.length > 0 ? Color.menu.text : Color.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.italic: root.filterText.length === 0
                        anchors.verticalCenter: parent.verticalCenter
                    }

                }

                Repeater {
                    model: root.displayModel

                    delegate: Rectangle {
                        required property var modelData
                        required property int index

                        width: content.width
                        height: root.rowHeight
                        radius: Style.cornerRadius
                        color: index === root.selectedIndex ? Color.menu.selectedBackground : "transparent"

                        Text {
                            text: modelData.title
                            color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            elide: Text.ElideRight
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: Style.space(8)
                            anchors.right: parent.right
                            anchors.rightMargin: Style.space(8)
                        }

                    }

                }

                Text {
                    text: root.displayModel.length === 0 ? "no results" : "enter: play   shift+enter: enqueue   ctrl+t: player   esc: close"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.small
                }

            }

        }

    }

}
