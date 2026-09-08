import QtQuick
import T3.Shell

// Keep a reference to this window in the owning layout, or let a Loader own
// its lifetime. Closing it does not close or navigate the primary window.
Window {
    id: root

    property alias url: view.url
    property alias storageId: view.storageId

    color: Theme.palette.color("chrome", "#0b0b0d")
    height: 780
    minimumHeight: 400
    minimumWidth: 640
    title: view.title || qsTr("T3 Code")
    visible: true
    width: 1100

    AppView {
        id: view

        anchors.fill: parent
        objectName: "independentAppView"
    }
}
