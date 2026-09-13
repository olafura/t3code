import QtQuick
import QtQuick.Layouts
import T3.Shell
import T3.Bricks

// The shape of a Mac app on macOS 26: the sidebar is the one Liquid Glass
// layer, edge to edge under a transparent title bar with the traffic lights
// and the sidebar toggle in it. The content column sits beside it on an
// opaque canvas behind a hairline, with the header strip sharing the title
// band, so there is a single row of chrome across the window.
ShellWindow {
    id: root

    readonly property color canvas: Theme.palette.color("canvas", "#fafafa")
    readonly property color hairline: Theme.palette.color("sidebarBorder", "#00000014")
    readonly property bool compact: width < 1100
    readonly property bool inspectorOverlay: width < 1400
    readonly property bool sidebarVisible: !root.sidebarCollapsed || root.settingsActive
    readonly property bool overlayActive: !root.settingsActive && ((root.compact && root.sidebarVisible) || (root.inspectorOverlay && inspector.visible))
    // The title band: AppKit's compact toolbar strip (PlatformWindow.mm
    // centres the traffic lights in it), which Qt reports as the top safe
    // area. Offscreen, or without the native backdrop, it is still one strip.
    readonly property real chromeHeight: Math.max(40, body.SafeArea.margins.top)
    // Where the first control goes once the traffic lights share its band.
    readonly property real lightsInset: 80
    property Item previousFocus: null

    function dismissOverlays() {
        if (root.compact && root.sidebarVisible)
            Shell.dispatch("sidebar.toggle");
        if (root.inspectorOverlay && rightPanel.open)
            Shell.dispatch("rightPanel.toggle");
    }

    function toggleMaximized() {
        root.visibility === Window.Maximized ? root.showNormal() : root.showMaximized();
    }

    color: Theme.windowTransparent ? "transparent" : root.canvas
    // AppKit keeps the traffic lights, window corners and resizing; the shell
    // draws under its transparent title bar and treats it as the top band.
    flags: Qt.Window | Qt.ExpandedClientAreaHint | Qt.NoTitleBarBackgroundHint
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

    // Drag anywhere in the title band; AppKit no longer owns that strip.
    component TitleBand: Item {
        implicitHeight: root.chromeHeight

        DragHandler {
            target: null

            onActiveChanged: if (active)
                root.startSystemMove()
        }
        TapHandler {
            onDoubleTapped: root.toggleMaximized()
        }
    }

    FocusScope {
        id: body

        anchors.fill: parent

        Keys.onEscapePressed: event => {
            if (root.overlayActive)
                root.dismissOverlays();
            else
                event.accepted = false;
        }

        // Content column: one opaque canvas so text stays crisp, with the
        // header strip in the title band.
        Rectangle {
            id: content

            anchors.fill: parent
            anchors.leftMargin: navigation.visible && (!root.compact || root.settingsActive) ? navigation.width : 0
            anchors.rightMargin: inspector.visible && !root.inspectorOverlay ? inspector.width : 0
            color: root.canvas
            enabled: !root.overlayActive
            objectName: "macContent"

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                TitleBand {
                    Layout.fillWidth: true

                    // The traffic lights land here whenever the sidebar is away.
                    MacToolbarButton {
                        id: showSidebar

                        anchors.verticalCenter: parent.verticalCenter
                        enabled: !root.settingsActive
                        icon.name: "sidebar.left"
                        text: qsTr("Show Sidebar")
                        visible: !navigation.visible
                        x: root.lightsInset

                        onClicked: Shell.dispatch("sidebar.toggle")
                    }
                    Workspace {
                        anchors.fill: parent
                        anchors.leftMargin: navigation.visible ? 0 : showSidebar.x + showSidebar.width - 8
                        anchors.rightMargin: trailing.width + 8
                        color: "transparent"
                        visible: ready
                    }
                    RowLayout {
                        id: trailing

                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        MacToolbarButton {
                            icon.name: "sidebar.right"
                            objectName: "macInspectorToggle"
                            text: rightPanel.open ? qsTr("Hide Inspector") : qsTr("Show Inspector")
                            visible: rightPanel.available && !root.settingsActive

                            onClicked: Shell.dispatch("rightPanel.toggle")
                        }
                        MacToolbarButton {
                            enabled: !root.settingsActive
                            icon.name: "gearshape"
                            text: qsTr("Settings…")

                            onClicked: Shell.dispatch("settings.open")
                        }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: root.hairline
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

        // Sidebar column: the glass itself. It paints nothing of its own
        // unless it floats over the content in a narrow window.
        Rectangle {
            id: navigation

            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.top: parent.top
            color: root.compact && !root.settingsActive ? Theme.palette.color("sidebar", "#f0f0f2") : "transparent"
            objectName: "macNavigation"
            visible: root.sidebarVisible
            width: 256

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                TitleBand {
                    Layout.fillWidth: true

                    MacToolbarButton {
                        anchors.verticalCenter: parent.verticalCenter
                        enabled: !root.settingsActive
                        icon.name: "sidebar.left"
                        objectName: "macSidebarToggle"
                        text: qsTr("Hide Sidebar")
                        x: root.lightsInset

                        onClicked: Shell.dispatch("sidebar.toggle")
                    }
                }
                Sidebar {
                    Layout.fillHeight: true
                    Layout.fillWidth: true
                    color: "transparent"
                    visible: !root.settingsActive
                }
                SettingsNav {
                    Layout.fillHeight: true
                    Layout.fillWidth: true
                    color: "transparent"
                    visible: root.settingsActive
                }
            }
            Rectangle {
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                anchors.top: parent.top
                color: root.hairline
                width: 1
            }
        }

        // Inspector column: beside the content in a wide window, over it
        // otherwise. Its tab row shares the title band.
        Rectangle {
            id: inspector

            anchors.bottom: parent.bottom
            anchors.right: parent.right
            anchors.top: parent.top
            color: Theme.palette.color("chrome", "#f0f0f2")
            objectName: "macInspector"
            visible: rightPanel.available && rightPanel.open && !root.settingsActive
            width: root.inspectorOverlay ? Math.min(360, body.width - 48) : Math.min(rightPanel.implicitWidth, root.width * 0.38)

            TitleBand {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
            }
            RightPanel {
                id: rightPanel

                anchors.fill: parent
                anchors.leftMargin: 1
                anchors.topMargin: root.chromeHeight - 36
                color: "transparent"
                ownToggle: false
            }
            Rectangle {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.top: parent.top
                color: root.hairline
                width: 1
            }
        }
    }
    Notifications {
        anchors.right: parent.right
        anchors.rightMargin: 20
        anchors.top: parent.top
        anchors.topMargin: root.chromeHeight + 12
    }
}
