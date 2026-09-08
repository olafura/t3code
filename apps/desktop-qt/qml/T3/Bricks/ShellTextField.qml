import QtQuick
import QtQuick.Controls.Basic
import T3.Shell

// A text input in the page's clothes.
TextField {
    id: control

    implicitHeight: 30
    leftPadding: 10
    rightPadding: 10
    font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
    font.pixelSize: 13
    color: Theme.palette.color("text", "#e4e4e7")
    placeholderTextColor: Theme.palette.color("placeholder", "#71717a")
    selectionColor: Theme.palette.color("accent", "#2563eb")
    selectedTextColor: Theme.palette.color("accentForeground", "#ffffff")

    background: Rectangle {
        radius: Math.min(Theme.radius, control.height / 2)
        color: Theme.palette.color("input", "#18181b")
        border.color: control.activeFocus ? Theme.palette.color("focus", "#3b82f6") : Theme.palette.color("border", "#27272a")
        border.width: 1
    }
}
