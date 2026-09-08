import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import T3.Shell

Dialog {
    id: dialog

    required property var folderModel
    property string operation: ""
    property string targetPath: ""
    readonly property string folderName: targetPath.split("/").filter(part => part.length > 0).pop() ?? ""
    signal operationFinished(string path)

    objectName: "folderOperationDialog"
    modal: true
    anchors.centerIn: parent
    width: Math.min(480, parent.width - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    title: operation === "create" ? qsTr("New folder") : operation === "rename" ? qsTr("Rename folder") : operation === "move" ? qsTr("Move folder") : qsTr("Move folder to Trash?")

    function begin(kind, path) {
        operation = kind;
        targetPath = path;
        entry.text = kind === "rename" ? folderName : "";
        errorLabel.text = "";
        open();
        entry.forceActiveFocus();
        entry.selectAll();
    }

    function commit() {
        let result = "";
        if (operation === "create") result = folderModel.createFolder(targetPath, entry.text);
        else if (operation === "rename") result = folderModel.renameFolder(targetPath, entry.text);
        else if (operation === "move") result = folderModel.moveFolder(targetPath, entry.text);
        else if (operation === "trash" && entry.text === folderName && folderModel.trashFolder(targetPath, targetPath)) result = folderModel.rootPath;
        if (result.length === 0) {
            errorLabel.text = folderModel.error;
            return;
        }
        operationFinished(result);
        accept();
    }

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }
    header: Label {
        text: dialog.title
        padding: 20
        bottomPadding: 4
        font.pixelSize: 17
        font.weight: Font.DemiBold
        color: Theme.palette.color("text", "#e4e4e7")
    }
    contentItem: ColumnLayout {
        spacing: 12
        Label {
            Layout.fillWidth: true
            text: dialog.targetPath
            font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
            font.pixelSize: 11
            color: Theme.palette.color("textMuted", "#a1a1aa")
            wrapMode: Text.WrapAnywhere
        }
        Label {
            Layout.fillWidth: true
            text: dialog.operation === "trash" ? qsTr("This moves the folder and everything inside it to your system Trash. It does not remove a project or its conversations from T3. Type the folder name to confirm.") : dialog.operation === "move" ? qsTr("Enter an existing destination folder inside the open folder tree. Existing folders will never be overwritten.") : qsTr("Choose a folder name. Existing folders will never be overwritten.")
            color: Theme.palette.color("text", "#e4e4e7")
            font.pixelSize: 13
            wrapMode: Text.Wrap
        }
        ShellTextField {
            id: entry
            objectName: "folderOperationInput"
            Layout.fillWidth: true
            placeholderText: dialog.operation === "trash" ? dialog.folderName : dialog.operation === "move" ? qsTr("Absolute destination folder") : qsTr("Folder name")
            Accessible.name: placeholderText
            onAccepted: if (submit.enabled) dialog.commit()
        }
        Label {
            id: errorLabel
            objectName: "folderOperationError"
            Layout.fillWidth: true
            visible: text.length > 0
            color: Theme.palette.color("error", "#ef4444")
            wrapMode: Text.Wrap
            font.pixelSize: 12
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 8
            Item { Layout.fillWidth: true }
            ShellButton {
                objectName: "folderOperationCancel"
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }
            ShellButton {
                id: submit
                objectName: "folderOperationConfirm"
                text: dialog.operation === "trash" ? qsTr("Move to Trash") : dialog.operation === "create" ? qsTr("Create folder") : dialog.operation === "rename" ? qsTr("Rename") : qsTr("Move")
                enabled: entry.text.trim().length > 0 && (dialog.operation !== "trash" || entry.text === dialog.folderName)
                tint: dialog.operation === "trash" ? Theme.palette.color("error", "#ef4444") : Theme.palette.color("text", "#e4e4e7")
                onClicked: dialog.commit()
            }
        }
    }
}
