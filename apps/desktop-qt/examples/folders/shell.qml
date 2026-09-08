import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import T3.Shell
import T3.Bricks

DefaultShell {
    id: root

    title: qsTr("T3 Code · folders")
    property string browsePath: ""
    navigationPanel: explorerComponent

    Component {
        id: explorerComponent
        FolderExplorer {
            rootPath: root.browsePath
            onRootPathChanged: root.browsePath = rootPath
        }
    }

    toolbar: Item {
        implicitHeight: 48
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 12
            Label {
                Layout.fillWidth: true
                text: qsTr("Drop a local folder to open it as a project")
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: 12
                elide: Text.ElideRight
            }
        }
    }
    ProjectFolderDrop {
        anchors.fill: parent
    }
}
