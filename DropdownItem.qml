import QtQuick
import qs.Common
import qs.Widgets

Item {
    id: root

    property var item: null
    property var pluginService: null
    property var popoutService: null
    // "both" | "icon" | "text"
    property string display: "both"

    // Submenu header state: expanded drives the chevron; indent nests children.
    readonly property bool isSubmenu: item ? item.type === "submenu" : false
    property bool expanded: false
    property real indent: 0
    signal toggleExpand()

    readonly property string _refId: item ? (item.widgetId || item.pluginId || "") : ""
    readonly property real _chevronSpace: isSubmenu ? (Theme.iconSize - 4) + Theme.spacingM : 0

    readonly property string resolvedIcon: {
        if (!item) return "extension"
        if (item.icon && item.icon !== "") return item.icon
        if (item.type === "submenu") return "folder"
        if ((item.type === "plugin" || item.type === "popout") && _refId && pluginService)
            return pluginService.availablePlugins[_refId]?.icon || "extension"
        return "extension"
    }

    readonly property string resolvedLabel: {
        if (!item) return ""
        if (item.label && item.label !== "") return item.label
        if ((item.type === "plugin" || item.type === "popout") && _refId && pluginService)
            return pluginService.availablePlugins[_refId]?.name || _refId
        return _refId
    }

    readonly property bool showIcon:  display !== "text"
    readonly property bool showLabel: display !== "icon"

    signal executeAction(string command)
    signal executePlugin(string pluginId)
    signal executePopout(string widgetId)

    implicitHeight: 48
    implicitWidth: 280

    StyledRect {
        anchors.fill: parent
        anchors.leftMargin: Theme.spacingS + root.indent
        anchors.rightMargin: Theme.spacingS
        radius: Theme.cornerRadius
        color: hoverArea.containsMouse ? Theme.surfaceContainerHighest : "transparent"

        Behavior on color {
            ColorAnimation { duration: Theme.shortDuration }
        }

        Row {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            spacing: root.showIcon && root.showLabel ? Theme.spacingM : 0

            DankIcon {
                name: root.resolvedIcon
                size: Theme.iconSize - 4
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
                visible: root.showIcon
            }

            StyledText {
                text: root.resolvedLabel
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                visible: root.showLabel
                width: (root.showIcon
                    ? parent.width - Theme.iconSize - Theme.spacingM * 2
                    : parent.width) - root._chevronSpace
            }
        }

        // Submenu expand/collapse affordance
        DankIcon {
            visible: root.isSubmenu
            name: root.expanded ? "expand_less" : "expand_more"
            size: Theme.iconSize - 4
            color: Theme.surfaceText
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
        }

        MouseArea {
            id: hoverArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (!root.item) return
                if (root.isSubmenu) {
                    root.toggleExpand()
                    return
                }
                if (root.item.type === "action")
                    root.executeAction(root.item.command || "")
                else if (root.item.type === "plugin")
                    root.executePlugin(root.item.pluginId || "")
                else if (root.item.type === "popout")
                    root.executePopout(root.item.widgetId || "")
            }
        }
    }
}
