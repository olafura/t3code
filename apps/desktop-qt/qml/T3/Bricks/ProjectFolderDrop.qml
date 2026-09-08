import QtQuick
import T3.Shell

// Overlay a shell with this opt-in drop target. Project registration is owned
// by the page; this component only resolves a directory on the client machine.
DropArea {
    id: root
    property string directoryPath: ""
    onEntered: drag => {
        directoryPath = drag.hasUrls && drag.urls.length === 1 ? Shell.localDirectoryPath(drag.urls[0]) : "";
        drag.accepted = directoryPath.length > 0;
    }
    onExited: directoryPath = ""
    onDropped: drop => {
        const path = drop.hasUrls && drop.urls.length === 1 ? Shell.localDirectoryPath(drop.urls[0]) : "";
        if (path.length > 0) {
            Shell.dispatch("project.folder.open", {
                path: path
            });
            drop.acceptProposedAction();
        } else {
            drop.accepted = false;
        }
        directoryPath = "";
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 12
        visible: root.containsDrag && root.directoryPath.length > 0
        color: Qt.alpha(Theme.palette.color("canvas", "#0f0f12"), 0.95)
        border.color: Theme.palette.color("accent", "#3b82f6")
        border.width: 2
        radius: 14
        Accessible.ignored: true
        Text {
            anchors.centerIn: parent
            width: Math.min(parent.width - 48, 640)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Open folder as a project\n%1\nNo files will be moved or deleted.").arg(root.directoryPath)
            color: Theme.palette.color("text", "#e4e4e7")
            font.pixelSize: 18
        }
    }
}
