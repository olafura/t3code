import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import QtQml.Models
import T3.Shell

Pane {
    id: explorer

    property alias rootPath: folders.rootPath
    property string selectedPath: ""
    property string statusText: ""
    readonly property var localProjects: Shell.state.sidebar?.localProjects ?? []
    readonly property bool localAccess: Shell.localFolderImportEnabled && (Shell.state.sidebar?.localEnvironmentId ?? null) !== null
    readonly property string actionPath: selectedPath.length > 0 ? selectedPath : rootPath
    readonly property bool directorySelected: localAccess && folders.isDirectory(actionPath)
    readonly property var selectedProject: localProjects.find(project => project.workspaceRoot === actionPath) ?? null
    readonly property bool canModifySelection: {
        // Native method calls do not establish dependencies on model properties.
        folders.protectedPaths;
        folders.enabled;
        return localAccess && folders.canModifyFolder(actionPath);
    }
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")

    objectName: "folderExplorer"
    implicitWidth: 340
    padding: 16
    palette.text: explorer.foreground
    palette.windowText: explorer.foreground
    palette.buttonText: explorer.foreground
    palette.highlight: Theme.palette.color("sidebarRowSelected", "#25314d")
    palette.highlightedText: explorer.foreground
    background: Rectangle { color: Theme.palette.color("sidebar", "#0a0a0a") }

    function openRoot(path) {
        folders.rootPath = path;
        selectedPath = "";
        statusText = "";
    }
    function beginOperation(operation) {
        operationDialog.begin(operation, actionPath);
    }
    function initializeRoot() {
        if (!localAccess || rootPath.length > 0) return;
        const activeRoot = Shell.state.workspace?.projectRoot ?? "";
        const project = localProjects.find(item => item.workspaceRoot === activeRoot) ?? localProjects[0];
        if (project) openRoot(project.workspaceRoot);
    }
    onLocalAccessChanged: initializeRoot()
    onLocalProjectsChanged: initializeRoot()
    onVisibleChanged: if (visible) initializeRoot()
    Component.onCompleted: initializeRoot()

    LocalFolderModel {
        id: folders
        objectName: "localFolderModel"
        enabled: explorer.localAccess && explorer.visible
        protectedPaths: explorer.localProjects.map(project => project.workspaceRoot)
    }
    FolderDialog {
        id: browse
        title: qsTr("Choose a local folder to manage")
        onAccepted: explorer.openRoot(Shell.localDirectoryPath(selectedFolder))
    }
    FolderOperationDialog {
        id: operationDialog
        parent: Overlay.overlay
        folderModel: folders
        onOperationFinished: path => {
            explorer.selectedPath = path;
            explorer.statusText = operation === "trash" ? qsTr("Folder moved to system Trash.") : qsTr("Folder updated on disk.");
        }
    }
    ShellMenu {
        id: contextMenu
        objectName: "folderContextMenu"
        implicitWidth: 230
        ShellMenuItem { text: qsTr("Open as project"); enabled: explorer.directorySelected; onTriggered: Shell.dispatch("project.folder.open", {path: explorer.actionPath}) }
        ShellMenuItem { text: qsTr("New folder…"); enabled: explorer.directorySelected; onTriggered: explorer.beginOperation("create") }
        MenuSeparator {}
        ShellMenuItem { objectName: "renameFolderMenuItem"; text: qsTr("Rename folder…"); enabled: explorer.canModifySelection; onTriggered: explorer.beginOperation("rename") }
        ShellMenuItem { objectName: "moveFolderMenuItem"; text: qsTr("Move folder…"); enabled: explorer.canModifySelection; onTriggered: explorer.beginOperation("move") }
        ShellMenuItem { objectName: "trashFolderMenuItem"; text: qsTr("Move to Trash…"); enabled: explorer.canModifySelection; onTriggered: explorer.beginOperation("trash") }
        MenuSeparator { visible: explorer.selectedProject !== null }
        ShellMenuItem {
            objectName: "removeFolderProjectMenuItem"
            text: qsTr("Remove from T3…")
            visible: explorer.selectedProject !== null
            onTriggered: {
                Shell.dispatch("project.remove", {projectKey: explorer.selectedProject.key});
            }
        }
    }
    contentItem: ColumnLayout {
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            ShellIcon { name: "folder-tree"; size: 20; color: Theme.palette.color("accent", "#3b82f6") }
            Label { Layout.fillWidth: true; text: qsTr("Explorer"); color: explorer.palette.text; font.pixelSize: 19; font.weight: Font.DemiBold }
            ShellButton { text: qsTr("Browse…"); enabled: explorer.localAccess; onClicked: browse.open() }
        }
        Label {
            Layout.fillWidth: true
            visible: !explorer.localAccess
            text: qsTr("Folder management is available only for a connected local environment. Attached servers must explicitly allow local folder access.")
            color: Theme.palette.color("textMuted", "#a1a1aa")
            wrapMode: Text.Wrap
        }
        ShellComboBox {
            objectName: "localFolderProjectPicker"
            Layout.fillWidth: true
            visible: explorer.localProjects.length > 0
            model: explorer.localProjects
            textRole: "displayName"
            currentIndex: explorer.localProjects.findIndex(project => project.workspaceRoot === explorer.rootPath)
            displayText: currentIndex >= 0 ? explorer.localProjects[currentIndex].displayName : qsTr("Custom folder")
            Accessible.name: qsTr("Local project")
            onActivated: index => explorer.openRoot(explorer.localProjects[index].workspaceRoot)
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: rootLabel.implicitHeight + 24
            radius: 8
            color: Theme.palette.color("surface", "#18181b")
            RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                Label {
                    id: rootLabel
                    Layout.fillWidth: true
                    text: explorer.rootPath.length > 0 ? explorer.rootPath : qsTr("Choose a folder to get started")
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: 11
                    font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                    wrapMode: Text.WrapAnywhere
                }
                ShellButton {
                    iconName: "ellipsis"
                    Accessible.name: qsTr("Root folder actions")
                    enabled: explorer.localAccess && explorer.rootPath.length > 0
                    onClicked: { explorer.selectedPath = ""; contextMenu.popup() }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            ShellButton { objectName: "newFolderButton"; text: qsTr("New folder"); iconName: "folder-plus"; enabled: explorer.directorySelected; onClicked: explorer.beginOperation("create") }
            Item { Layout.fillWidth: true }
            Label { text: qsTr("LOCAL"); color: Theme.palette.color("textMuted", "#a1a1aa"); font.pixelSize: 10; font.letterSpacing: 1 }
        }
        TreeView {
            id: tree
            objectName: "folderTree"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            // Qt 6.11 can retain a recycled delegate's old filesystem roles
            // when expansion shifts visible rows. Keep each row's own delegate.
            reuseItems: false
            model: folders.enabled && explorer.rootPath.length > 0 ? folders : null
            rootIndex: folders.rootIndex
            columnWidthProvider: column => column === 0 ? tree.width : 0
            selectionModel: ItemSelectionModel {
                model: tree.model
                onCurrentChanged: explorer.selectedPath = folders.pathForIndex(currentIndex)
            }
            editTriggers: TableView.NoEditTriggers
            ScrollBar.vertical: ScrollBar {}
            delegate: TreeViewDelegate {
                id: folderRow
                required property string fileName
                required property string filePath
                required property bool isDirectory
                implicitWidth: tree.width
                implicitHeight: 38
                text: fileName
                highlighted: explorer.selectedPath === filePath
                palette: explorer.palette
                contentItem: RowLayout {
                    spacing: 8
                    ShellIcon { name: folderRow.isDirectory ? (folderRow.expanded ? "folder-open" : "folder") : "file-text"; size: 16; color: Theme.palette.color(folderRow.isDirectory ? "accent" : "textMuted", "#3b82f6") }
                    Label { Layout.fillWidth: true; text: folderRow.fileName; color: explorer.palette.text; font.pixelSize: 13; elide: Text.ElideRight }
                }
                background: Rectangle {
                    radius: 6
                    color: folderRow.highlighted ? Theme.palette.color("sidebarRowSelected", "#25314d") : folderRow.hovered ? Theme.palette.color("surface", "#18181b") : "transparent"
                }
                onClicked: explorer.selectedPath = filePath
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: {
                        explorer.selectedPath = folderRow.filePath;
                        contextMenu.popup(folderRow, 0, folderRow.height);
                    }
                }
            }
        }
        Label {
            Layout.fillWidth: true
            visible: folders.error.length > 0 || explorer.statusText.length > 0
            text: folders.error.length > 0 ? folders.error : explorer.statusText
            color: folders.error.length > 0 ? Theme.palette.color("error", "#ef4444") : Theme.palette.color("textMuted", "#a1a1aa")
            wrapMode: Text.Wrap
            font.pixelSize: 12
        }
        Label {
            Layout.fillWidth: true
            text: explorer.selectedProject !== null ? qsTr("Registered project roots stay in place to protect thread paths. Remove from T3 deletes its conversation history, not its files.") : !explorer.directorySelected && explorer.selectedPath.length > 0 ? qsTr("Files are shown read-only. Right-click a folder to manage it.") : qsTr("Right-click a folder to rename, move or trash it. Disk changes affect every app using these files.")
            color: Theme.palette.color("textMuted", "#a1a1aa")
            wrapMode: Text.Wrap
            font.pixelSize: 11
        }
    }
}
