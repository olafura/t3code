import QtQuick
import QtQuick.Layouts
import T3.Shell
import T3.Bricks

ShellWindow {
    id: root

    readonly property color canvas: Theme.palette.color("canvas", "#fafafa")
    readonly property bool compact: width < 1100
    readonly property bool inspectorOverlay: width < 1400
    readonly property bool overlayActive: !root.settingsActive && ((root.compact && navigation.visible) || (root.inspectorOverlay && rightPanel.visible))
    property Item previousFocus: null
    readonly property bool sidebarVisible: !root.sidebarCollapsed || root.settingsActive

    function dismissOverlays() {
        if (root.compact && root.sidebarVisible)
            Shell.dispatch("sidebar.toggle");
        if (root.inspectorOverlay && rightPanel.open)
            Shell.dispatch("rightPanel.toggle");
    }

    color: Theme.windowTransparent ? "transparent" : root.canvas
    // AppKit owns the titlebar, traffic lights, window corners and resizing.
    flags: Qt.Window
    height: 860
    width: 1360

    onOverlayActiveChanged: {
        if (root.overlayActive) {
            root.previousFocus = root.activeFocusItem;
            body.forceActiveFocus(Qt.PopupFocusReason);
        } else if (root.previousFocus) {
            root.previousFocus.forceActiveFocus(Qt.PopupFocusReason);
            root.previousFocus = null;
        }
    }

    Rectangle {
        Accessible.ignored: true
        anchors.fill: parent
        color: Qt.alpha(root.canvas, 0.55)
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Keys.onEscapePressed: event => {
            if (root.overlayActive)
                root.dismissOverlays();
            else
                event.accepted = false;
        }

        MacToolbar {
            Layout.fillWidth: true
            Layout.margins: 12
            panelAvailable: rightPanel.available
            panelOpen: rightPanel.open
            settingsActive: root.settingsActive
            sidebarCollapsed: root.sidebarCollapsed
        }
        FocusScope {
            id: body

            Layout.fillHeight: true
            Layout.fillWidth: true

            Rectangle {
                id: content

                anchors.fill: parent
                anchors.leftMargin: navigation.visible && (!root.compact || root.settingsActive) ? navigation.width + 16 : 0
                anchors.rightMargin: rightPanel.visible && !root.inspectorOverlay ? rightPanel.width : 0
                clip: true
                color: root.canvas
                enabled: !root.overlayActive
                objectName: "macContent"

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    Workspace {
                        Layout.fillWidth: true
                        color: root.canvas
                        visible: ready
                    }
                    WebSurface {
                        Layout.fillHeight: true
                        Layout.fillWidth: true
                        backgroundColor: root.canvas
                        url: Shell.pageUrl
                    }
                    Composer {
                        Layout.fillWidth: true
                        color: root.canvas
                        visible: ready
                    }
                    TerminalDrawer {
                        Layout.fillWidth: true
                    }
                }
            }
            Rectangle {
                Accessible.ignored: true
                anchors.fill: content
                color: Theme.palette.color("navigationScrim", "#33000000")
                visible: root.overlayActive

                TapHandler {
                    onTapped: root.dismissOverlays()
                }
            }
            Rectangle {
                id: navigation

                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.margins: 8
                anchors.top: parent.top
                color: root.compact ? Theme.palette.color("sidebar", "#f0f0f2") : "transparent"
                objectName: "macNavigation"
                radius: 16
                visible: root.sidebarVisible
                width: 256

                Sidebar {
                    anchors.fill: parent
                    color: "transparent"
                    visible: !root.settingsActive
                }
                SettingsNav {
                    anchors.fill: parent
                    color: "transparent"
                    visible: root.settingsActive
                }
            }
            RightPanel {
                id: rightPanel

                anchors.bottom: parent.bottom
                anchors.right: parent.right
                anchors.top: parent.top
                color: root.inspectorOverlay ? Theme.palette.color("chrome", "#f0f0f2") : "transparent"
                objectName: "macInspector"
                ownToggle: false
                visible: available && open && !root.settingsActive
                width: root.inspectorOverlay ? Math.min(360, body.width - 48) : Math.min(implicitWidth, root.width * 0.38)
            }
        }
    }
    Notifications {
        anchors.right: parent.right
        anchors.rightMargin: 20
        anchors.top: parent.top
        anchors.topMargin: 64
    }
}
