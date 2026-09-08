import QtQuick
import QtTest
import "../qml/T3/Bricks"
import T3.Shell

Item {
    id: root
    width: 900
    height: 700

    Component {
        id: component
        Composer {
            id: composer
            width: 800
            height: 650
            property alias vim: vim
            ComposerVimKeys {
                id: vim
                composer: composer
            }
        }
    }

    TestCase {
        name: "ComposerExtensionTests"
        when: windowShown
        function init() {
            Shell.reset();
        }
        function cleanup() {
            Shell.reset();
        }

        function test_unicodeInsertionReplacesSelectionWithoutSending() {
            const composer = createTemporaryObject(component, root);
            verify(!!composer, "Component exists");
            composer.editor.text = qsTr("before OLD after");
            composer.editor.select(7, 10);
            compare(composer.insertText(qsTr("把 src/auth.ts 里的 verifyToken 改掉"), composer.publishedTarget), true);
            compare(composer.editor.text, qsTr("before 把 src/auth.ts 里的 verifyToken 改掉 after"));
            compare(Shell.dispatchCount, 1);
            compare(Shell.dispatchedActions[0].action, "composer.text.set");
            compare(Shell.dispatchedActions[0].payload.text, composer.editor.text);
        }

        function test_delayedTranscriptDoesNotWriteIntoAnotherThread() {
            const composer = createTemporaryObject(component, root);
            verify(!!composer, "Component exists");
            const target = composer.publishedTarget;
            Shell.publishComposerTarget("other-thread", qsTr("Another draft"), 3);
            compare(composer.insertText(qsTr("Transcript"), target), false);
            compare(composer.editor.text, qsTr("Another draft"));
            compare(Shell.dispatchCount, 0);
        }

        function test_disabledEditorRejectsExternalInsertion() {
            Shell.state = {
                composer: Object.assign({}, Shell.defaultComposer(), {
                    editorDisabled: true
                }),
                workspace: null
            };
            const composer = createTemporaryObject(component, root);
            verify(!!composer, "Component exists");
            compare(composer.insertText(qsTr("Transcript")), false);
            compare(Shell.dispatchCount, 0);
        }

        function test_vimModeIsOptInAndDoesNotSubmitNormalModeEnter() {
            const composer = createTemporaryObject(component, root);
            verify(!!composer, "Component exists");
            compare(composer.vim.vimEnabled, false);
            composer.editor.text = qsTr("hello 123 /path");
            composer.editor.focus = true;
            composer.editor.forceActiveFocus();
            composer.vim.vimEnabled = true;
            keyClick(Qt.Key_Escape);
            compare(composer.vim.insertMode, false);
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchCount, 0);
            compare(composer.editor.text, qsTr("hello 123 /path"));
            composer.vim.vimEnabled = false;
            compare(composer.vim.insertMode, true);
        }

        function test_vimMovementDeletionAndInsertEntry() {
            const composer = createTemporaryObject(component, root);
            verify(!!composer, "Component exists");
            composer.editor.text = qsTr("hello world\nsecond");
            composer.editor.cursorPosition = 0;
            composer.editor.focus = true;
            composer.editor.forceActiveFocus();
            composer.vim.vimEnabled = true;
            keyClick(Qt.Key_Escape);
            keyClick(Qt.Key_W);
            compare(composer.editor.cursorPosition, 6);
            keyClick(Qt.Key_X);
            compare(composer.editor.text, qsTr("hello orld\nsecond"));
            keyClick(Qt.Key_J);
            compare(composer.editor.cursorPosition, 17);
            keyClick(Qt.Key_K);
            compare(composer.editor.cursorPosition, 6);
            keyClick(Qt.Key_I);
            compare(composer.vim.insertMode, true);
        }
    }
}
