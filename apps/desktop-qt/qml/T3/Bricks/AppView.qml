import QtQuick
import T3.Shell

// An independent, fully interactive web client for a split pane or window.
// Cookies and settings share WebProfile; navigation and native actions do not.
// Use WebSurface for the primary page and its coordinated embedded panels.
WebSurface {
    // Choose before creation. A stable, unique ID restores this pane's drafts
    // and panels after restart. The default isolates this view's lifetime.
    property string storageId: "view-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2)

    shellIntegration: false
    independentStorageId: storageId
    url: Shell.pageUrl
}
