import QtQuick
import QtTest
import "../qml/T3/Bricks"
import T3.Shell

Item {
    id: root
    width: 1000
    height: 700

    Component {
        id: component
        Composer {
            id: composer
            width: 800
            height: implicitHeight
            editorActions: [
                ShellButton {
                    objectName: "insertTranscript"
                    text: qsTr("Insert transcript")
                    onClicked: composer.insertText(qsTr("把 verifyToken 改掉"))
                },
                ShellButton {
                    objectName: "toggleVim"
                    text: qsTr("Enable composer Vim mode")
                    checkable: true
                }
            ]
        }
    }

    TestCase {
        name: "ComposerActionsTests"
        when: windowShown
        function init() {
            Shell.reset();
        }
        function cleanup() {
            Shell.reset();
        }

        function test_toolbarActionsStayInsideComposer_data() {
            return [
                {
                    tag: "narrow",
                    width: 320
                },
                {
                    tag: "medium",
                    width: 640
                },
                {
                    tag: "wide",
                    width: 900
                }
            ];
        }
        function test_toolbarActionsStayInsideComposer(data) {
            const composer = createTemporaryObject(component, root, {
                width: data.width
            });
            verify(!!composer, "Component exists");
            const first = findChild(composer, "insertTranscript");
            const second = findChild(composer, "toggleVim");
            verify(!!first, "Object exists");
            verify(!!second, "Object exists");
            verify(waitForRendering(composer));
            const firstPoint = first.mapToItem(composer, 0, 0);
            const secondPoint = second.mapToItem(composer, 0, 0);
            verify(firstPoint.x >= 0 && firstPoint.x + first.width <= composer.width);
            verify(secondPoint.x >= 0 && secondPoint.x + second.width <= composer.width);
            if (data.width === 320)
                verify(secondPoint.y >= firstPoint.y + first.height);
            mouseClick(first);
            tryCompare(composer.editor, "text", qsTr("把 verifyToken 改掉"));
            compare(Shell.dispatchedActions[0].action, "composer.text.set");
        }
    }
}
