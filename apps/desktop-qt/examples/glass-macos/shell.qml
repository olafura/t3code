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
    // The page's own breakpoints: the sidebar goes off-canvas under 768 and
    // the right panel becomes a sheet under 980. Above them both sit beside
    // the content, as in the app.
    readonly property bool compact: width < 768
    readonly property bool inspectorOverlay: width < 980
    readonly property bool sidebarVisible: !root.sidebarCollapsed || root.settingsActive
    // Settings navigation always takes the column, even in a narrow window.
    readonly property bool sidebarOverlay: root.compact && !root.settingsActive
    readonly property bool inspectorShown: rightPanel.available && rightPanel.open && !root.settingsActive
    readonly property bool overlayActive: !root.settingsActive && ((root.sidebarOverlay && root.sidebarVisible) || (root.inspectorOverlay && root.inspectorShown))
    readonly property int slideDuration: 220
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

    component Slide: NumberAnimation {
        duration: root.slideDuration
        easing.type: Easing.OutCubic
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
            // Bound to the animated widths, so the content follows the slide.
            anchors.leftMargin: root.sidebarOverlay ? 0 : navigation.width
            anchors.rightMargin: root.inspectorOverlay ? 0 : inspector.width
            // The page's last frame keeps its own size until Chromium delivers
            // the next; clipped, it cannot bleed under a sliding panel.
            clip: true
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

                        Behavior on anchors.leftMargin {
                            Slide {}
                        }
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
                // The drawer folds open under the composer. It keeps its open
                // height while the slot around it animates, so the document
                // never relayouts mid-slide; dragging the edge stays instant.
                Item {
                    id: terminalSlot

                    property int openHeight: 0
                    property real reveal: terminal.open ? 1 : 0

                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.round(openHeight * reveal)
                    clip: true
                    objectName: "macTerminal"

                    Behavior on reveal {
                        Slide {}
                    }

                    TerminalDrawer {
                        id: terminal

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: terminalSlot.openHeight
                        visible: terminalSlot.height > 0

                        onImplicitHeightChanged: if (open)
                            terminalSlot.openHeight = implicitHeight
                        onOpenChanged: if (open)
                            terminalSlot.openHeight = implicitHeight
                    }
                }
            }
        }
        Rectangle {
            Accessible.ignored: true
            anchors.fill: content
            color: Theme.palette.color("navigationScrim", "#33000000")
            opacity: root.overlayActive ? 1 : 0
            visible: opacity > 0

            Behavior on opacity {
                Slide {}
            }
            TapHandler {
                onTapped: root.dismissOverlays()
            }
        }

        // Sidebar column: the glass itself. It paints nothing of its own
        // unless it floats over the content in a narrow window. Beside the
        // content it folds to zero width; over it, it slides in from the edge.
        Rectangle {
            id: navigation

            readonly property int openWidth: 256

            anchors.bottom: parent.bottom
            anchors.top: parent.top
            clip: true
            color: root.sidebarOverlay ? Theme.palette.color("sidebar", "#f0f0f2") : "transparent"
            objectName: "macNavigation"
            visible: width > 0 && x > -width
            width: root.sidebarVisible || root.sidebarOverlay ? openWidth : 0
            x: root.sidebarOverlay && !root.sidebarVisible ? -openWidth : 0

            // One eased axis per mode: the width folds beside the content, x
            // slides over it. Easing both lets one lag the other.
            Behavior on width {
                enabled: !root.sidebarOverlay

                Slide {}
            }
            Behavior on x {
                enabled: root.sidebarOverlay

                Slide {}
            }

            // Fixed to the open width so nothing reflows while the column folds.
            ColumnLayout {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.top: parent.top
                spacing: 0
                width: navigation.openWidth

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

        // Inspector column: beside the content in a wide window, folding to
        // zero width; a sheet sliding in over it otherwise. Its tab row
        // shares the title band.
        Rectangle {
            id: inspector

            readonly property real openWidth: root.inspectorOverlay ? Math.min(360, body.width - 48) : Math.min(rightPanel.openWidth, root.width * 0.38)

            anchors.bottom: parent.bottom
            anchors.top: parent.top
            clip: true
            color: Theme.palette.color("chrome", "#f0f0f2")
            objectName: "macInspector"
            visible: width > 0 && x < body.width
            width: root.inspectorShown || root.inspectorOverlay ? openWidth : 0
            x: root.inspectorOverlay && !root.inspectorShown ? body.width : body.width - width

            Behavior on width {
                enabled: !root.inspectorOverlay

                Slide {}
            }
            Behavior on x {
                enabled: root.inspectorOverlay

                Slide {}
            }

            TitleBand {
                anchors.left: parent.left
                anchors.top: parent.top
                width: inspector.openWidth
            }
            // Fixed to the open width so the document keeps its size while
            // the column folds.
            RightPanel {
                id: rightPanel

                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.leftMargin: 1
                anchors.top: parent.top
                anchors.topMargin: root.chromeHeight - 36
                color: "transparent"
                ownToggle: false
                width: inspector.openWidth - 1
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
