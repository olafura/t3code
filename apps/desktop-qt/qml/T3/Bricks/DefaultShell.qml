import QtQuick
import QtQuick.Layouts
import T3.Shell
import T3.Bricks

// Built-in layout, laid out like the page's own chrome: sidebar, header
// strip, timeline, composer. A user's ~/.t3/shell/shell.qml replaces this
// file wholesale; it is also the fallback when that file fails to load.
// Frameless windows get their drag handle and window buttons from the
// sidebar band and the header strip rather than a separate title bar.
ShellWindow {
    id: root

    // Local QML extensions can customize one brick without copying the layout.
    property alias sidebar: sidebarView
    property alias composer: composerView
    property alias workspace: workspaceView
    property alias webView: primaryView
    property alias terminalDrawer: terminalView
    property alias rightPanel: panelView
    property alias toolbar: toolbarLoader.sourceComponent
    property alias navigationPanel: sidebarExtension.sourceComponent

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            GridLayout {
                id: navigation
                Layout.fillHeight: true
                Layout.fillWidth: false
                Layout.preferredWidth: columns === 2 ? 256 + sidebarExtension.implicitWidth : sidebarExtension.active ? 300 : 256
                Layout.maximumWidth: Layout.preferredWidth
                Layout.minimumWidth: 0
                columns: sidebarExtension.active && root.width >= 1100 ? 2 : 1
                rowSpacing: 0
                columnSpacing: 0
                visible: !root.settingsActive && !root.sidebarCollapsed

                Sidebar {
                    id: sidebarView
                    objectName: "threadSidebar"
                    Layout.fillHeight: true
                    Layout.fillWidth: true
                    Layout.preferredWidth: 256
                    Layout.minimumWidth: 0
                    showBrand: true
                    window: root
                }

                Loader {
                    id: sidebarExtension
                    Layout.fillHeight: true
                    Layout.fillWidth: true
                    Layout.preferredWidth: status === Loader.Ready && item ? item.implicitWidth : 0
                    active: sourceComponent !== null
                    visible: active
                }
            }

            SettingsNav {
                Layout.fillHeight: true
                Layout.preferredWidth: 256
                visible: root.settingsActive
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Workspace {
                    id: workspaceView

                    Layout.fillWidth: true
                    visible: ready
                    sidebarToggle: root.sidebarCollapsed
                    panelToggle: panelView.available ? panelView.open : null
                    window: root
                }

                Loader {
                    id: toolbarLoader
                    objectName: "extensionToolbar"

                    Layout.fillWidth: true
                    Layout.preferredHeight: status === Loader.Ready && item ? item.implicitHeight : 0
                    active: sourceComponent !== null
                    visible: active
                }

                WebSurface {
                    id: primaryView

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    url: Shell.pageUrl
                }

                Composer {
                    id: composerView

                    Layout.fillWidth: true
                    visible: ready
                }

                TerminalDrawer {
                    id: terminalView

                    Layout.fillWidth: true
                }
            }

            RightPanel {
                id: panelView

                Layout.fillHeight: true
                ownToggle: false
                Layout.preferredWidth: implicitWidth
                visible: available
            }
        }
    }

    Notifications {
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.bottomMargin: 180
        anchors.rightMargin: 16
    }
}
