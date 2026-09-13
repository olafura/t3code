import QtQuick
import QtQuick.Controls.macOS

// One toolbar item in AppKit's clothes: the SF Symbol named by `icon.name`,
// with `text` as its tooltip and accessible name, the way Mac toolbars label
// icon-only actions.
Button {
    Accessible.name: text
    ToolTip.delay: 500
    ToolTip.text: text
    ToolTip.visible: hovered || visualFocus
    display: AbstractButton.IconOnly
    flat: true
    icon.height: 20
    icon.width: 20
    implicitWidth: 40
}
