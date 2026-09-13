import QtQuick
import QtQuick.Controls.macOS
import QtQuick.Layouts
import T3.Shell

RowLayout {
    id: root

    required property bool panelAvailable
    required property bool panelOpen
    required property bool settingsActive
    required property bool sidebarCollapsed

    spacing: 8

    RowLayout {
        spacing: 8

        Button {
            Accessible.name: text
            Layout.preferredWidth: 40
            ToolTip.delay: 500
            ToolTip.text: text
            ToolTip.visible: hovered || visualFocus
            display: AbstractButton.IconOnly
            enabled: !root.settingsActive
            flat: true
            icon.height: 20
            icon.name: "sidebar.left"
            icon.width: 20
            objectName: "macSidebarToggle"
            text: root.sidebarCollapsed ? qsTr("Show Sidebar") : qsTr("Hide Sidebar")

            onClicked: Shell.dispatch("sidebar.toggle")
        }
        Button {
            Accessible.name: text
            Layout.preferredWidth: 40
            ToolTip.delay: 500
            ToolTip.text: text
            ToolTip.visible: hovered || visualFocus
            display: AbstractButton.IconOnly
            enabled: Shell.state.sidebar !== undefined
            flat: true
            icon.height: 20
            icon.name: "square.and.pencil"
            icon.width: 20
            text: qsTr("New Thread")

            onClicked: Shell.dispatch("thread.new")
        }
    }
    Item {
        Layout.fillWidth: true
    }
    RowLayout {
        spacing: 8

        Button {
            Accessible.name: text
            Layout.preferredWidth: 40
            ToolTip.delay: 500
            ToolTip.text: text
            ToolTip.visible: hovered || visualFocus
            display: AbstractButton.IconOnly
            flat: true
            icon.height: 20
            icon.name: "sidebar.right"
            icon.width: 20
            objectName: "macInspectorToggle"
            text: root.panelOpen ? qsTr("Hide Inspector") : qsTr("Show Inspector")
            visible: root.panelAvailable && !root.settingsActive

            onClicked: Shell.dispatch("rightPanel.toggle")
        }
        Button {
            Accessible.name: text
            Layout.preferredWidth: 40
            ToolTip.delay: 500
            ToolTip.text: text
            ToolTip.visible: hovered || visualFocus
            display: AbstractButton.IconOnly
            enabled: !root.settingsActive
            flat: true
            icon.height: 20
            icon.name: "gearshape"
            icon.width: 20
            text: qsTr("Settings…")

            onClicked: Shell.dispatch("settings.open")
        }
    }
}
