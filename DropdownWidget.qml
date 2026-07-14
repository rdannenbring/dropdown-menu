import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property string variantId: ""
    property var variantData: null
    property var popoutService: null

    // Re-read variantData directly when plugin data changes
    Connections {
        target: pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId !== root.pluginId || root.variantId === "") return
            const fresh = pluginService.getPluginVariantData(root.pluginId, root.variantId)
            if (fresh) root.variantData = fresh
        }
    }

    readonly property string pillIcon:    variantData?.icon        || "expand_circle_down"
    readonly property string pillText:    variantData?.text        || ""
    readonly property string pillDisplay: variantData?.pillDisplay || "both"
    readonly property var    menuItems:   variantData?.items       ?? []

    readonly property bool pillShowIcon:  pillDisplay !== "text"
    readonly property bool pillShowLabel: pillDisplay !== "icon" && pillText !== ""

    popoutWidth: 280

    // Accordion expansion state, keyed by top-level item index → bool. Lives on
    // root (not in the ephemeral popout content) so popoutHeight can see it.
    readonly property int _rowH: 48
    property var _expandedSubmenus: ({})
    onMenuItemsChanged: _expandedSubmenus = ({})   // stale indices if items change

    function _toggleSubmenu(index) {
        const m = Object.assign({}, _expandedSubmenus)
        m[index] = !m[index]
        _expandedSubmenus = m
    }

    // Grow to fit expanded submenus: one row per top-level item, plus each
    // expanded submenu's children. (One level; deeper nesting would recurse.)
    popoutHeight: {
        let rows = 0
        for (var i = 0; i < menuItems.length; i++) {
            rows += 1
            const it = menuItems[i]
            if (it && it.type === "submenu" && _expandedSubmenus[i] && it.items)
                rows += it.items.length
        }
        return Math.max(64, rows * _rowH + 16)
    }

    Behavior on popoutHeight {
        NumberAnimation { duration: Theme.shortDuration; easing.type: Easing.OutCubic }
    }

    // Plugin/widget ids to instantiate off-bar so menu items work without the
    // widget being on a bar:
    //   • "popout" items  → so the widget exists to call triggerPopout() on.
    //   • plugin "action" items (IPC) → so the plugin's IpcHandler (declared in
    //     its widget) is live and `dms ipc …` resolves.
    readonly property var _hostedTargets: {
        const out = []
        const add = (id) => { if (id && out.indexOf(id) < 0) out.push(id) }
        // Recurse into submenu children so nested popout/IPC items host off-bar
        // too. Depth is unbounded here even though rendering is one level; this
        // stays a flat, de-duped target list (compatible with lazy hosting, #2).
        const walk = (items) => {
            if (!items) return
            for (var i = 0; i < items.length; i++) {
                const it = items[i]
                if (!it) continue
                if (it.type === "submenu") walk(it.items)
                else if (it.type === "popout" && it.widgetId) add(it.widgetId)
                else if (it.type === "action" && it.pluginId) add(it.pluginId)
            }
        }
        walk(menuItems)
        return out
    }

    // Set by whichever bar pill (horizontal/vertical) is currently realized, so
    // the popout dispatch can reach the on-demand host living in the bar window.
    property var _popoutHost: null

    // Open a widget's popout: prefer our off-bar instance; fall back to a copy
    // that's actually placed on a bar (BarWidgetService).
    function _openWidgetPopout(widgetId) {
        if (_popoutHost && _popoutHost.trigger(widgetId))
            return true
        return BarWidgetService.triggerWidgetPopout(widgetId)
    }

    // ── On-demand popout host ────────────────────────────────────────────────
    // A zero-size, clipped, non-interactive host placed inside the bar pill. It
    // instantiates each "popout" target widget off-bar (hidden) and exposes
    // trigger(widgetId) to open that widget's own popout, anchored where the
    // host sits (the dropdown button). Clipping to 0×0 keeps the embedded
    // widgets invisible and unclickable while still letting them lay out, so
    // triggerPopout() can compute a correct on-screen position. Inlined (rather
    // than a sibling .qml) so it hot-reloads without a full shell restart.
    Component {
        id: popoutHostComp

        Item {
            id: hostItem
            width: 0
            height: 0
            clip: true

            Component.onDestruction: if (root._popoutHost === hostItem) root._popoutHost = null

            function trigger(widgetId) {
                for (var i = 0; i < memberRep.count; i++) {
                    const m = memberRep.itemAt(i)
                    if (m && m.targetId === widgetId && m.openPopout())
                        return true
                }
                return false
            }

            Repeater {
                id: memberRep
                model: root._hostedTargets

                delegate: Item {
                    id: mem
                    required property var modelData
                    anchors.centerIn: parent

                    readonly property string targetId: modelData
                    readonly property var _parts: targetId ? targetId.split(":") : []
                    readonly property string _pluginId: _parts.length > 0 ? _parts[0] : ""
                    readonly property string _variantId: _parts.length > 1 ? _parts[1] : ""
                    readonly property var _component: (root.pluginService && _pluginId && root.pluginService.pluginWidgetComponents)
                        ? (root.pluginService.pluginWidgetComponents[_pluginId] || null)
                        : null

                    function openPopout() {
                        if (memLoader.item && typeof memLoader.item.triggerPopout === "function") {
                            memLoader.item.triggerPopout()
                            return true
                        }
                        return false
                    }

                    Loader {
                        id: memLoader
                        active: mem._component !== null
                        sourceComponent: mem._component
                        anchors.centerIn: parent

                        onLoaded: {
                            if (!item)
                                return
                            try {
                                if ("pluginId" in item)      item.pluginId = mem._pluginId
                                if ("variantId" in item)     item.variantId = mem._variantId
                                if (mem._variantId && "variantData" in item && root.pluginService?.getPluginVariantData)
                                    item.variantData = root.pluginService.getPluginVariantData(mem._pluginId, mem._variantId)
                                if ("pluginService" in item) item.pluginService = root.pluginService
                                if ("popoutService" in item) item.popoutService = root.popoutService
                            } catch (e) {
                                console.warn("[dropdownMenu] on-demand injection failed for", mem.targetId, ":", e)
                            }
                        }
                    }

                    Binding { target: memLoader.item; when: memLoader.item && "axis" in memLoader.item;            property: "axis";            value: root.axis;            restoreMode: Binding.RestoreNone }
                    Binding { target: memLoader.item; when: memLoader.item && "section" in memLoader.item;         property: "section";         value: root.section;         restoreMode: Binding.RestoreNone }
                    Binding { target: memLoader.item; when: memLoader.item && "parentScreen" in memLoader.item;    property: "parentScreen";    value: root.parentScreen;    restoreMode: Binding.RestoreNone }
                    Binding { target: memLoader.item; when: memLoader.item && "widgetThickness" in memLoader.item; property: "widgetThickness"; value: root.widgetThickness; restoreMode: Binding.RestoreNone }
                    Binding { target: memLoader.item; when: memLoader.item && "barThickness" in memLoader.item;    property: "barThickness";    value: root.barThickness;    restoreMode: Binding.RestoreNone }
                    Binding { target: memLoader.item; when: memLoader.item && "barSpacing" in memLoader.item;      property: "barSpacing";      value: root.barSpacing;      restoreMode: Binding.RestoreNone }
                    Binding { target: memLoader.item; when: memLoader.item && "barConfig" in memLoader.item;       property: "barConfig";       value: root.barConfig;       restoreMode: Binding.RestoreNone }
                    Binding { target: memLoader.item; when: memLoader.item && "blurBarWindow" in memLoader.item;   property: "blurBarWindow";   value: root.blurBarWindow;   restoreMode: Binding.RestoreNone }
                }
            }
        }
    }

    // ── Horizontal bar pill ──────────────────────────────────────────────────

    horizontalBarPill: Component {
        Item {
            implicitWidth: hRow.implicitWidth
            implicitHeight: hRow.implicitHeight

            Row {
                id: hRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    name: root.pillIcon
                    size: root.iconSize
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.pillShowIcon
                }

                StyledText {
                    text: root.pillText
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.pillShowLabel
                }
            }

            Loader {
                anchors.centerIn: parent
                sourceComponent: popoutHostComp
                onLoaded: root._popoutHost = item
            }
        }
    }

    // ── Vertical bar pill ────────────────────────────────────────────────────

    verticalBarPill: Component {
        Item {
            implicitWidth: vCol.implicitWidth
            implicitHeight: vCol.implicitHeight

            Column {
                id: vCol
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    name: root.pillIcon
                    size: root.iconSize
                    color: Theme.surfaceText
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.pillShowIcon
                }

                StyledText {
                    text: root.pillText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.horizontalCenter: parent.horizontalCenter
                    horizontalAlignment: Text.AlignHCenter
                    visible: root.pillShowLabel
                }
            }

            Loader {
                anchors.centerIn: parent
                sourceComponent: popoutHostComp
                onLoaded: root._popoutHost = item
            }
        }
    }

    // ── Popout (dropdown) content ────────────────────────────────────────────

    popoutContent: Component {
        PopoutComponent {
            id: popoutRoot
            showCloseButton: false

            Process {
                id: actionProcess
                running: false
            }

            // Shared dispatch so submenu headers and nested children reuse it.
            function _dispatchAction(command) {
                actionProcess.command = ["sh", "-c", command]
                actionProcess.running = true
                root.closePopout()
            }
            function _dispatchPlugin(pluginId) {
                root._triggerPlugin(pluginId)
                root.closePopout()
            }
            function _dispatchPopout(widgetId) {
                root.closePopout()
                if (!root._openWidgetPopout(widgetId))
                    ToastService.showWarning("Couldn't open " + widgetId + " — it isn't an installed widget plugin")
            }

            Column {
                width: parent.width
                spacing: 2
                topPadding: Theme.spacingS
                bottomPadding: Theme.spacingS

                Repeater {
                    model: root.menuItems

                    // Each top-level entry is a header/leaf row plus, for a
                    // submenu, an animated container of its indented children.
                    delegate: Column {
                        id: itemGroup
                        required property var modelData
                        required property int index

                        width: parent.width
                        spacing: 2

                        readonly property bool isSubmenu: modelData && modelData.type === "submenu"
                        readonly property var subItems: (isSubmenu && modelData.items) ? modelData.items : []

                        DropdownItem {
                            width: parent.width
                            item: itemGroup.modelData
                            display: (itemGroup.modelData && itemGroup.modelData.display) || "both"
                            pluginService: root.pluginService
                            popoutService: root.popoutService
                            expanded: !!root._expandedSubmenus[itemGroup.index]

                            onToggleExpand: root._toggleSubmenu(itemGroup.index)
                            onExecuteAction: (command) => popoutRoot._dispatchAction(command)
                            onExecutePlugin: (pluginId) => popoutRoot._dispatchPlugin(pluginId)
                            onExecutePopout: (widgetId) => popoutRoot._dispatchPopout(widgetId)
                        }

                        // Nested children (one level). Deeper nesting would
                        // recurse a submenu delegate in place of DropdownItem here.
                        Item {
                            width: parent.width
                            clip: true
                            visible: itemGroup.isSubmenu
                            height: (itemGroup.isSubmenu && !!root._expandedSubmenus[itemGroup.index])
                                ? childrenCol.implicitHeight : 0

                            Behavior on height {
                                NumberAnimation { duration: Theme.shortDuration; easing.type: Easing.OutCubic }
                            }

                            Column {
                                id: childrenCol
                                width: parent.width
                                spacing: 2

                                Repeater {
                                    model: itemGroup.subItems

                                    delegate: DropdownItem {
                                        required property var modelData

                                        width: parent.width
                                        item: modelData
                                        display: (modelData && modelData.display) || "both"
                                        indent: Theme.spacingL
                                        pluginService: root.pluginService
                                        popoutService: root.popoutService

                                        onExecuteAction: (command) => popoutRoot._dispatchAction(command)
                                        onExecutePlugin: (pluginId) => popoutRoot._dispatchPlugin(pluginId)
                                        onExecutePopout: (widgetId) => popoutRoot._dispatchPopout(widgetId)
                                    }
                                }
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    text: "No items configured"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    horizontalAlignment: Text.AlignHCenter
                    topPadding: Theme.spacingM
                    bottomPadding: Theme.spacingM
                    visible: root.menuItems.length === 0
                }
            }
        }
    }

    // ── Plugin trigger dispatch ──────────────────────────────────────────────

    readonly property var _builtinPlugins: ({
        "controlCenter":       () => popoutService?.toggleControlCenter(),
        "notificationCenter":  () => popoutService?.toggleNotificationCenter(),
        "appDrawer":           () => popoutService?.toggleAppDrawer(),
        "processList":         () => popoutService?.toggleProcessList(),
        "battery":             () => popoutService?.toggleBattery(),
        "vpn":                 () => popoutService?.toggleVpn(),
        "systemUpdate":        () => popoutService?.toggleSystemUpdate(),
        "settings":            () => popoutService?.openSettings(),
        "clipboardHistory":    () => popoutService?.openClipboardHistory(),
        "spotlight":           () => popoutService?.toggleDankLauncherV2(),
        "powerMenu":           () => popoutService?.togglePowerMenu(),
        "colorPicker":         () => popoutService?.showColorPicker(),
        "notepad":             () => popoutService?.toggleNotepad()
    })

    function _triggerPlugin(pluginId) {
        const builtin = _builtinPlugins[pluginId]
        if (builtin) builtin()
        else if (pluginService) pluginService.togglePlugin(pluginId)
    }
}
