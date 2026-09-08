import QtQuick

// A small opt-in modal editor, not a complete Vim implementation.
Item {
    id: root
    required property var composer
    property bool vimEnabled: false
    property bool insertMode: true
    readonly property string modeLabel: !vimEnabled ? qsTr("Vim off") : insertMode ? qsTr("INSERT") : qsTr("NORMAL")

    onVimEnabledChanged: insertMode = true

    Connections {
        target: root.composer
        function onPublishedTargetChanged() {
            root.insertMode = true;
        }
        function onEditorKeyPressed(event) {
            const editor = root.composer.editor;
            if (!root.vimEnabled || editor.inputMethodComposing || event.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier))
                return;
            if (event.key === Qt.Key_Escape) {
                if (root.composer.suggesting)
                    return;
                root.insertMode = false;
                editor.deselect();
                event.accepted = true;
                return;
            }
            if (root.insertMode)
                return;
            // Normal-mode Enter must not accidentally submit a prompt.
            event.accepted = true;
            const text = editor.text;
            const position = editor.cursorPosition;
            const lineStart = text.slice(0, position).lastIndexOf("\n") + 1;
            const nextNewline = text.indexOf("\n", position);
            const lineEnd = nextNewline < 0 ? text.length : nextNewline;
            switch (event.text) {
            case "i":
                root.insertMode = true;
                break;
            case "a":
                editor.cursorPosition = Math.min(position + 1, lineEnd);
                root.insertMode = true;
                break;
            case "I":
                editor.cursorPosition = lineStart;
                root.insertMode = true;
                break;
            case "A":
                editor.cursorPosition = lineEnd;
                root.insertMode = true;
                break;
            case "h":
                editor.cursorPosition = Math.max(lineStart, position - 1);
                break;
            case "l":
                editor.cursorPosition = Math.min(lineEnd, position + 1);
                break;
            case "0":
                editor.cursorPosition = lineStart;
                break;
            case "$":
                editor.cursorPosition = lineEnd;
                break;
            case "j":
                if (lineEnd < text.length) {
                    const nextEnd = text.indexOf("\n", lineEnd + 1);
                    editor.cursorPosition = Math.min(lineEnd + 1 + position - lineStart, nextEnd < 0 ? text.length : nextEnd);
                }
                break;
            case "k":
                if (lineStart > 0) {
                    const previousStart = text.slice(0, lineStart - 1).lastIndexOf("\n") + 1;
                    editor.cursorPosition = Math.min(previousStart + position - lineStart, lineStart - 1);
                }
                break;
            case "w":
                {
                    const match = /\S+\s*/.exec(text.slice(position));
                    editor.cursorPosition = match ? position + match.index + match[0].length : text.length;
                    break;
                }
            case "b":
                {
                    const prefix = text.slice(0, position).replace(/\s+$/, "");
                    const match = /\S+$/.exec(prefix);
                    editor.cursorPosition = match ? match.index : 0;
                    break;
                }
            case "x":
                if (position < lineEnd)
                    editor.remove(position, position + 1);
                break;
            case "u":
                editor.undo();
                break;
            }
        }
    }
}
