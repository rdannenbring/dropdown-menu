import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "dropdownMenu"

    // The variant currently being edited in Section B
    property string editingVariantId: ""
    property var editingVariant: null

    // Drill-in navigation for sub-menus. -1 = editing the variant's root items;
    // >=0 = editing that root submenu's children. One level for now: deeper
    // nesting would make this a path (array of indices) instead of a single int.
    property int editingSubmenuIndex: -1
    property string editingSubmenuLabel: ""
    readonly property bool _atRoot: editingSubmenuIndex < 0

    onVariantsChanged: {
        localVariantsModel.clear()
        for (let i = 0; i < variants.length; i++) {
            const v = variants[i]
            localVariantsModel.append({
                vid: v.id || "",
                vname: v.name || "",
                vicon: v.icon || "expand_circle_down",
                vtext: v.text || ""
            })
        }
        if (editingVariantId !== "") {
            const found = variants.find(v => v.id === editingVariantId) || null
            editingVariant = found
            // If an external change removed/retyped the submenu we're inside, pop
            // back to root so we don't edit a phantom level.
            if (editingSubmenuIndex >= 0) {
                const rootItems = found?.items ?? []
                const sm = rootItems[editingSubmenuIndex]
                if (!sm || sm.type !== "submenu") _drillOut()
            }
            _syncItemsModel()
        }
    }

    ListModel {
        id: localVariantsModel
    }

    // New Variant Form state
    property string newVariantName: ""
    property string newVariantIcon: "expand_circle_down"
    property string newVariantText: ""

    // New Item Form state
    property string newItemType: "action"
    property string newItemIcon: ""
    property string newItemLabel: ""
    property string newItemCommand: ""
    property string newItemPluginId: ""
    // Owning plugin of an IPC action being edited via the raw "action" form, so the
    // plugin association survives an edit (the widget hosts it to keep IPC live).
    property string newItemActionPluginId: ""
    property string newItemDisplay: "both"
    property string editingPillDisplay: "both"
    property int editingItemIndex: -1   // -1 = adding new; >=0 = editing that item

    // IPC discovery state
    property string newItemIpcTarget: ""
    property string newItemIpcFunction: ""
    property string newItemIpcArgs: ""
    property var ipcTargets: []          // [{ target, functions: [..] }]
    property bool ipcLoaded: false
    property bool ipcLoading: false

    readonly property var ipcTargetNames: ipcTargets.map(t => t.target)

    readonly property var ipcFunctionsForTarget: {
        for (let i = 0; i < ipcTargets.length; i++)
            if (ipcTargets[i].target === newItemIpcTarget)
                return ipcTargets[i].functions
        return []
    }

    readonly property string ipcCommandPreview: {
        if (!newItemIpcTarget || !newItemIpcFunction) return ""
        let c = "dms ipc " + newItemIpcTarget + " " + newItemIpcFunction
        if (newItemIpcArgs.trim() !== "") c += " " + newItemIpcArgs.trim()
        return c
    }

    function _loadIpcTargets() {
        if (ipcLoading) return
        ipcLoading = true
        ipcDiscoverProcess.running = true
    }

    function _parseIpcHelp(text) {
        const lines = text.split('\n')
        const out = []
        let inTargets = false
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i]
            if (line.indexOf('Targets:') === 0) { inTargets = true; continue }
            if (!inTargets) continue
            const m = line.match(/^\s+(\S+)\s+(.+)$/)
            if (m) {
                const target = m[1]
                const funcs = m[2].split(',').map(s => s.trim()).filter(s => s.length > 0)
                if (funcs.length > 0) out.push({ target: target, functions: funcs })
            }
        }
        out.sort((a, b) => a.target.localeCompare(b.target))
        ipcTargets = out
        ipcLoaded = true
        ipcLoading = false
        // If a plugin detection was waiting on the live target list, build it now.
        if (_detectingFor && _pluginCandidateTargets.length > 0)
            _buildPluginCommands(_detectingFor)
    }

    Process {
        id: ipcDiscoverProcess
        command: ["dms", "ipc", "--help"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._parseIpcHelp(text)
        }
        onExited: (exitCode) => {
            root.ipcLoading = false
            if (exitCode !== 0 && root.ipcTargets.length === 0)
                ToastService.showError("Could not load IPC targets (is DMS running?)")
        }
    }

    // ── Per-plugin command detection ─────────────────────────────────────────
    // Scans a selected plugin's QML for IpcHandler target names, intersects with
    // the live IPC target list, and offers those functions instead of a bare toggle.
    property var pluginCommandOptions: []   // IPC actions: [{ label, target, fn }]
    property string newPluginCmdTarget: ""
    property string newPluginCmdFn: ""
    property string newPluginActionKind: "toggle"   // toggle | popout | embed | ipc
    property bool pluginScanning: false
    property string _detectingFor: ""
    property var _pluginCandidateTargets: []

    readonly property bool _selectedIsWidget: {
        const p = pluginService?.availablePlugins?.[newItemPluginId]
        if (!p || !p.pluginDirectory) return false
        if (p.type && p.type !== "widget") return false
        return !!(pluginService?.pluginWidgetComponents && pluginService.pluginWidgetComponents[newItemPluginId])
    }

    // Full tagged action list for the selected plugin: default + popout + IPC.
    // Widget plugins have no meaningful "toggle" (togglePlugin only drives daemon
    // slideouts / built-in panels), so their primary action is opening the popout.
    readonly property var pluginActionOptions: {
        const opts = []
        if (_selectedIsWidget)
            opts.push({ label: "Open its popout", kind: "popout" })
        else
            opts.push({ label: "Toggle / open (default)", kind: "toggle" })
        for (let i = 0; i < pluginCommandOptions.length; i++) {
            const o = pluginCommandOptions[i]
            opts.push({ label: "Action: " + o.label, kind: "ipc", target: o.target, fn: o.fn })
        }
        return opts
    }

    function _detectPluginCommands(pluginId) {
        pluginCommandOptions = []
        newPluginCmdTarget = ""
        newPluginCmdFn = ""
        // Widget plugins default to "Open its popout" (their only useful default);
        // built-ins/daemons default to toggle.
        newPluginActionKind = _selectedIsWidget ? "popout" : "toggle"
        _pluginCandidateTargets = []
        _detectingFor = pluginId
        // Show the default action in the picker (popout for widgets, toggle otherwise)
        // rather than a blank field. IPC actions, if any, append after this default.
        if (pluginCommandPicker)
            pluginCommandPicker.currentValue = pluginActionOptions.length > 0 ? pluginActionOptions[0].label : ""
        if (!pluginId)
            return
        // NOTE: IPC discovery (`dms ipc --help`) is deliberately NOT auto-run here.
        // It enumerates every registered IpcHandler and can crash the shell via an
        // upstream quickshell `wireDef` segfault on an un-wireable handler. So the
        // plugin's toggle/popout default works with no discovery; mapping detected
        // targets → IPC actions only happens if the user explicitly opts in (which
        // sets ipcLoaded and re-runs _buildPluginCommands via _parseIpcHelp). The
        // QML target-name scan below is harmless (local find|grep, no IPC).
        // Built-ins have no plugin directory — they use the standard toggle.
        const plugin = pluginService?.availablePlugins?.[pluginId]
        const dir = plugin?.pluginDirectory
        if (!dir)
            return
        pluginScanning = true
        pluginScanProcess.command = ["sh", "-c",
            "find -L '" + dir + "' -name '*.qml' -print0 2>/dev/null | "
            + "xargs -0 grep -hoE 'target:[[:space:]]*\"[^\"]+\"' 2>/dev/null"]
        pluginScanProcess.running = true
    }

    function _onPluginScanFinished(text) {
        pluginScanning = false
        const names = []
        const lines = text.split('\n')
        for (let i = 0; i < lines.length; i++) {
            const m = lines[i].match(/"([^"]+)"/)
            if (m && names.indexOf(m[1]) === -1)
                names.push(m[1])
        }
        _pluginCandidateTargets = names
        _buildPluginCommands(_detectingFor)
    }

    function _buildPluginCommands(pluginId) {
        if (pluginId !== _detectingFor)
            return
        const liveByName = {}
        for (let i = 0; i < ipcTargets.length; i++)
            liveByName[ipcTargets[i].target] = ipcTargets[i].functions
        const matched = _pluginCandidateTargets.filter(t => liveByName[t])
        const multi = matched.length > 1
        const opts = []
        const seen = {}
        for (let i = 0; i < matched.length; i++) {
            const target = matched[i]
            const fns = liveByName[target]
            for (let j = 0; j < fns.length; j++) {
                const key = target + ":" + fns[j]
                if (seen[key]) continue
                seen[key] = true
                opts.push({ label: (multi ? target + ": " : "") + fns[j], target: target, fn: fns[j] })
            }
        }
        pluginCommandOptions = opts
    }

    Process {
        id: pluginScanProcess
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._onPluginScanFinished(text)
        }
        onExited: (exitCode) => {
            if (exitCode !== 0 && root.pluginScanning) {
                root.pluginScanning = false
                root.pluginCommandOptions = []
            }
        }
    }

    // Helpers
    ListModel { id: localItemsModel }

    // Items for the level currently being edited: the variant's root items, or
    // — when drilled in — the children of the submenu at editingSubmenuIndex.
    function _levelItems() {
        const rootItems = editingVariant?.items ?? []
        if (editingSubmenuIndex >= 0 && editingSubmenuIndex < rootItems.length) {
            const sm = rootItems[editingSubmenuIndex]
            return (sm && sm.items) ? sm.items : []
        }
        return rootItems
    }

    function _syncItemsModel() {
        localItemsModel.clear()
        const items = _levelItems()
        for (let i = 0; i < items.length; i++) {
            const it = items[i]
            localItemsModel.append({
                itype:     it.type      || "action",
                iicon:     it.icon      || "",
                ilabel:    it.label     || "",
                icommand:  it.command   || "",
                ipluginId: it.pluginId  || "",
                iwidgetId: it.widgetId  || "",
                idisplay:  it.display   || "both",
                // Submenu children round-trip as JSON — ListModel can't hold
                // nested arrays; the drill-in editor rebuilds them from here.
                isubJson:  JSON.stringify(it.items || [])
            })
        }
    }

    // Persist the current level's items back into the variant. At root that's a
    // straight write; drilled in, it splices the children into their submenu and
    // writes the whole root array (submenu icon/label preserved via assign).
    function _saveItems(items) {
        if (!editingVariantId || !pluginService) return
        let rootItems
        if (editingSubmenuIndex >= 0) {
            rootItems = (editingVariant?.items ?? []).slice()
            if (editingSubmenuIndex < rootItems.length)
                rootItems[editingSubmenuIndex] = Object.assign({}, rootItems[editingSubmenuIndex], { items: items })
        } else {
            rootItems = items
        }
        updateVariant(editingVariantId, { items: rootItems })
        // Update the local model immediately — don't wait for the reactive chain
        editingVariant = Object.assign({}, editingVariant, { items: rootItems })
        _syncItemsModel()
    }

    // ── Sub-menu drill-in navigation ─────────────────────────────────────────
    function _drillInto(index) {
        const r = localItemsModel.get(index)
        if (!r || r.itype !== "submenu") return
        editingSubmenuIndex = index
        editingSubmenuLabel = r.ilabel || "Sub-menu"
        _resetItemForm()
        _syncItemsModel()
        submenuNameField.text = r.ilabel || ""
        submenuIconPicker.currentIcon = r.iicon || "folder"
    }

    function _drillOut() {
        editingSubmenuIndex = -1
        editingSubmenuLabel = ""
        _resetItemForm()
        _syncItemsModel()
    }

    // Rename / re-icon the submenu we're drilled into (children untouched).
    function _saveSubmenuMeta() {
        if (!editingVariantId || !pluginService || editingSubmenuIndex < 0) return
        const rootItems = (editingVariant?.items ?? []).slice()
        if (editingSubmenuIndex >= rootItems.length) return
        const label = submenuNameField.text.trim()
        const sm = Object.assign({}, rootItems[editingSubmenuIndex], {
            icon: submenuIconPicker.currentIcon,
            label: label
        })
        rootItems[editingSubmenuIndex] = sm
        updateVariant(editingVariantId, { items: rootItems })
        editingVariant = Object.assign({}, editingVariant, { items: rootItems })
        editingSubmenuLabel = label || "Sub-menu"
    }

    function _currentItems() {
        const items = []
        for (let i = 0; i < localItemsModel.count; i++) {
            const r = localItemsModel.get(i)
            const obj = { type: r.itype, icon: r.iicon, label: r.ilabel, display: r.idisplay }
            if (r.itype === "submenu") {
                obj.items = JSON.parse(r.isubJson || "[]")   // preserve nested children
            } else if (r.itype === "action") {
                obj.command = r.icommand
                // IPC actions sourced from a plugin carry the owning pluginId so the
                // widget can instantiate it off-bar (keeping its IpcHandler live).
                if (r.ipluginId) obj.pluginId = r.ipluginId
            } else if (r.itype === "popout") obj.widgetId = r.iwidgetId
            else obj.pluginId = r.ipluginId   // plugin | embed
            items.push(obj)
        }
        return items
    }

    function _selectVariant(variant) {
        editingVariantId = variant.id
        editingVariant = variant
        editingPillDisplay = variant.pillDisplay || "both"
        editingSubmenuIndex = -1   // always land at the variant's root level
        editingSubmenuLabel = ""
        _syncItemsModel()
        // Populate the meta-edit fields
        editNameField.text = variant.name || ""
        editLabelField.text = variant.text || ""
        editIconPicker.currentIcon = variant.icon || "expand_circle_down"
        // Reset the add-item form
        _resetItemForm()
    }

    function _resetItemForm() {
        editingItemIndex = -1
        newItemType = "action"
        newItemIcon = ""
        newItemLabel = ""
        newItemCommand = ""
        newItemPluginId = ""
        newItemActionPluginId = ""
        newItemDisplay = "both"
        newItemIpcTarget = ""
        newItemIpcFunction = ""
        newItemIpcArgs = ""
        newPluginCmdTarget = ""
        newPluginCmdFn = ""
        newPluginActionKind = "toggle"
        pluginCommandOptions = []
        _detectingFor = ""
        actionIconField.currentIcon = ""
        actionLabelField.text = ""
        actionCommandField.text = ""
        pluginIconField.currentIcon = ""
        pluginLabelField.text = ""
        pluginCommandPicker.currentValue = ""
        ipcIconField.currentIcon = ""
        ipcLabelField.text = ""
        ipcArgsField.text = ""
        ipcTargetPicker.currentValue = ""
        ipcFunctionPicker.currentValue = ""
        pluginPicker.currentValue = ""
        submenuFormIcon.currentIcon = ""
        submenuFormLabel.text = ""
    }

    function _editItem(index) {
        const r = localItemsModel.get(index)
        if (!r) return
        if (r.itype === "submenu") {
            // A submenu row isn't edited via the form — clicking it drills into
            // its children (rename/re-icon happens in the drilled-in header).
            _drillInto(index)
            return
        }
        _resetItemForm()
        editingItemIndex = index
        newItemDisplay = r.idisplay || "both"
        newItemIcon = r.iicon || ""
        newItemLabel = r.ilabel || ""
        if (r.itype === "action") {
            newItemType = "action"
            newItemCommand = r.icommand || ""
            newItemActionPluginId = r.ipluginId || ""
            actionIconField.currentIcon = r.iicon || ""
            actionLabelField.text = r.ilabel || ""
            actionCommandField.text = r.icommand || ""
        } else {
            // plugin or popout
            newItemType = "plugin"
            newItemPluginId = (r.itype === "popout") ? (r.iwidgetId || "") : (r.ipluginId || "")
            pluginIconField.currentIcon = r.iicon || ""
            pluginLabelField.text = r.ilabel || ""
            if (newItemPluginId) pluginPicker.currentValue = _displayNameFor(newItemPluginId)
            _detectPluginCommands(newItemPluginId)
            // _detectPluginCommands resets kind to "toggle"; restore the intended kind
            newPluginActionKind = (r.itype === "popout") ? "popout" : "toggle"
        }
    }

    function _savePillDisplay(value) {
        if (!editingVariantId || !pluginService) return
        editingPillDisplay = value
        updateVariant(editingVariantId, { pillDisplay: value })
        editingVariant = Object.assign({}, editingVariant, { pillDisplay: value })
    }

    function _saveVariantMeta() {
        if (!editingVariantId || !pluginService) return
        const newName = editNameField.text.trim()
        const newText = editLabelField.text.trim()
        if (!newName) return
        updateVariant(editingVariantId, { name: newName, text: newText })
        editingVariant = Object.assign({}, editingVariant, { name: newName, text: newText })
        for (let i = 0; i < localVariantsModel.count; i++) {
            if (localVariantsModel.get(i).vid === editingVariantId) {
                localVariantsModel.setProperty(i, "vname", newName)
                localVariantsModel.setProperty(i, "vtext", newText)
                break
            }
        }
    }

    function _saveVariantIcon(iconName) {
        if (!editingVariantId || !pluginService) return
        updateVariant(editingVariantId, { icon: iconName })
        editingVariant = Object.assign({}, editingVariant, { icon: iconName })
        for (let i = 0; i < localVariantsModel.count; i++) {
            if (localVariantsModel.get(i).vid === editingVariantId) {
                localVariantsModel.setProperty(i, "vicon", iconName)
                break
            }
        }
    }

    // Set of plugin ids that are currently placed on any bar (any section)
    readonly property var _pluginsOnBar: {
        const set = ({})
        const bars = SettingsData.barConfigs || []
        for (let b = 0; b < bars.length; b++) {
            const lists = [bars[b].leftWidgets, bars[b].centerWidgets, bars[b].rightWidgets]
            for (let l = 0; l < lists.length; l++) {
                const arr = lists[l] || []
                for (let i = 0; i < arr.length; i++) {
                    const w = arr[i]
                    const wid = (typeof w === "string") ? w : (w ? w.id : "")
                    if (!wid) continue
                    set[wid.split(":")[0]] = true   // strip :variantId
                }
            }
        }
        return set
    }

    function _pluginOnBar(id) { return _pluginsOnBar[id] === true }
    function _pluginEnabled(id) {
        return !!(pluginService && pluginService.availablePlugins[id] && pluginService.availablePlugins[id].loaded)
    }

    // Bumped on enable/disable so the picker labels re-evaluate live
    property int _pluginStateRev: 0
    Connections {
        target: pluginService
        function onPluginLoaded(id) { root._pluginStateRev++ }
        function onPluginUnloaded(id) { root._pluginStateRev++ }
    }

    // Available plugin list for the picker (built-ins + installed)
    readonly property var availablePluginList: {
        const builtins = [
            { id: "controlCenter",      name: "Control Center",       isPlugin: false, isWidget: false },
            { id: "notificationCenter", name: "Notification Center",  isPlugin: false, isWidget: false },
            { id: "appDrawer",          name: "App Drawer",           isPlugin: false, isWidget: false },
            { id: "processList",        name: "Process List",         isPlugin: false, isWidget: false },
            { id: "battery",            name: "Battery Info",         isPlugin: false, isWidget: false },
            { id: "vpn",                name: "VPN",                  isPlugin: false, isWidget: false },
            { id: "systemUpdate",       name: "System Update",        isPlugin: false, isWidget: false },
            { id: "settings",           name: "Settings",             isPlugin: false, isWidget: false },
            { id: "clipboardHistory",   name: "Clipboard History",    isPlugin: false, isWidget: false },
            { id: "spotlight",          name: "Spotlight / Launcher", isPlugin: false, isWidget: false },
            { id: "powerMenu",          name: "Power Menu",           isPlugin: false, isWidget: false },
            { id: "colorPicker",        name: "Color Picker",         isPlugin: false, isWidget: false },
            { id: "notepad",            name: "Notepad",              isPlugin: false, isWidget: false }
        ]
        if (!pluginService) return builtins
        // Only plugins we can actually drive from the menu: widgets (open popout)
        // and daemons (toggle / IPC). Desktop and launcher plugins are excluded.
        const installed = pluginService.availablePluginsList
            .filter(p => p.id !== "dropdownMenu" && p.id !== "widgetGroup"
                      && (p.type === "widget" || p.type === "daemon"))
            .map(p => ({ id: p.id, name: p.name, isPlugin: true, isWidget: p.type === "widget" }))
            .sort((a, b) => a.name.localeCompare(b.name))
        return builtins.concat(installed)
    }

    // Flag plugins that won't work: not enabled (any action), or — for widgets —
    // not on any bar (so "Open its popout" can't reach them).
    function _pluginDisplayName(p) {
        if (p.isPlugin && !_pluginEnabled(p.id)) return p.name + "  —  not enabled"
        if (p.isWidget && !_pluginOnBar(p.id))   return p.name + "  —  not on a bar"
        return p.name
    }
    function _displayNameFor(id) {
        const p = availablePluginList.find(x => x.id === id)
        return p ? _pluginDisplayName(p) : id
    }

    readonly property var availablePluginNames: {
        _pluginsOnBar; _pluginStateRev   // re-evaluate when bars or enable-state change
        return availablePluginList.map(p => _pluginDisplayName(p))
    }

    readonly property var quickAddItems: [
        { pluginId: "controlCenter",      label: "Control Center",  icon: "settings" },
        { pluginId: "notificationCenter", label: "Notifications",   icon: "notifications" },
        { pluginId: "appDrawer",          label: "App Drawer",      icon: "apps" },
        { pluginId: "spotlight",          label: "Spotlight",       icon: "search" },
        { pluginId: "powerMenu",          label: "Power Menu",      icon: "power_settings_new" },
        { pluginId: "clipboardHistory",   label: "Clipboard",       icon: "content_paste" },
        { pluginId: "notepad",            label: "Notepad",         icon: "edit_note" },
        { pluginId: "colorPicker",        label: "Color Picker",    icon: "colorize" },
        { pluginId: "processList",        label: "Process List",    icon: "memory" },
        { pluginId: "settings",           label: "Settings",        icon: "manage_accounts" }
    ]

    // ════════════════════════════════════════════════════════════════════════
    // Section A — Variant Manager
    // ════════════════════════════════════════════════════════════════════════

    StyledText {
        width: parent.width
        text: "Dropdown Menus"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Each dropdown is a separate bar widget. Add them to your bar via Bar Settings → Add Widget."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // Usage hint
    StyledRect {
        width: parent.width
        height: hintColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surface

        Column {
            id: hintColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingS

            Row {
                spacing: Theme.spacingS
                DankIcon { name: "info"; size: Theme.iconSize; color: Theme.primary; anchors.verticalCenter: parent.verticalCenter }
                StyledText {
                    text: "How to use"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                width: parent.width
                text: "1. Create a dropdown above, then click it to edit (click again to collapse)\n2. Add items: a Custom Action (shell command), a Plugin (toggle / open popout / IPC action), or an IPC Command\n3. Quick Add chips instantly add common panels — added ones stay highlighted until removed\n4. Click any item in the list to edit it; use the arrows to reorder or ✕ to remove\n5. The bar pill can show an icon, text, or both (set in the editor)\n6. Go to Bar Settings → Add Widget to place the dropdown on your bar\n\nClicking the dropdown on the bar opens/closes its menu."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                lineHeight: 1.5
            }
        }
    }

    // Create new variant form
    StyledRect {
        width: parent.width
        height: createColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: createColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Add New Dropdown"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            Row {
                width: parent.width
                spacing: Theme.spacingM

                Column {
                    width: (parent.width - Theme.spacingM * 2) / 3
                    spacing: Theme.spacingXS
                    StyledText { text: "Name"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                    DankTextField {
                        id: variantNameField
                        width: parent.width
                        placeholderText: "My Menu"
                        onTextChanged: root.newVariantName = text
                    }
                    StyledText {
                        width: parent.width
                        text: "Shown in Add Widget picker"
                        font.pixelSize: 10
                        color: Theme.surfaceVariantText
                        opacity: 0.7
                        wrapMode: Text.WordWrap
                    }
                }

                Column {
                    width: (parent.width - Theme.spacingM * 2) / 3
                    spacing: Theme.spacingXS
                    StyledText { text: "Icon"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                    DropdownIconPicker {
                        id: variantIconField
                        width: parent.width
                        currentIcon: "expand_circle_down"
                        onIconSelected: (name) => {
                            root.newVariantIcon = name
                        }
                    }
                    StyledText {
                        width: parent.width
                        text: "Material icon name"
                        font.pixelSize: 10
                        color: Theme.surfaceVariantText
                        opacity: 0.7
                        wrapMode: Text.WordWrap
                    }
                }

                Column {
                    width: (parent.width - Theme.spacingM * 2) / 3
                    spacing: Theme.spacingXS
                    StyledText { text: "Label"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                    DankTextField {
                        id: variantTextField
                        width: parent.width
                        placeholderText: "Menu"
                        onTextChanged: root.newVariantText = text
                    }
                    StyledText {
                        width: parent.width
                        text: "Text shown on bar pill (leave blank for icon only)"
                        font.pixelSize: 10
                        color: Theme.surfaceVariantText
                        opacity: 0.7
                        wrapMode: Text.WordWrap
                    }
                }
            }

            DankButton {
                text: "Create Dropdown"
                iconName: "add"
                onClicked: {
                    if (!root.newVariantName) {
                        ToastService.showError("Please enter a name for the dropdown")
                        return
                    }
                    const newId = createVariant(root.newVariantName, {
                        icon: root.newVariantIcon || "expand_circle_down",
                        text: root.newVariantText,
                        items: []
                    })
                    if (newId) {
                        // Reload the plugin so the bar settings widget picker
                        // picks up the new variant immediately
                        Qt.callLater(() => pluginService.reloadPlugin("dropdownMenu"))
                        ToastService.showInfo("Dropdown created: " + root.newVariantName)
                    } else {
                        ToastService.showError("Failed to save — plugin service unavailable")
                    }
                    root.newVariantName = ""
                    root.newVariantIcon = "expand_circle_down"
                    root.newVariantText = ""
                    variantNameField.text = ""
                    variantIconField.currentIcon = "expand_circle_down"
                    root.newVariantIcon = "expand_circle_down"
                    variantTextField.text = ""
                }
            }
        }
    }

    // Existing variants list
    StyledRect {
        width: parent.width
        height: Math.max(80, variantsListColumn.implicitHeight + Theme.spacingL * 2)
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: variantsListColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingS

            StyledText {
                text: "Your Dropdowns"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StyledText {
                visible: localVariantsModel.count === 0
                width: parent.width
                text: "No dropdowns yet. Create one above."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Repeater {
                model: localVariantsModel

                delegate: StyledRect {
                    required property string vid
                    required property string vname
                    required property string vicon
                    required property string vtext
                    required property int index

                    width: variantsListColumn.width
                    height: variantRow.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: root.editingVariantId === vid
                        ? Theme.primaryContainer
                        : (rowHover.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer)

                    Behavior on color { ColorAnimation { duration: Theme.shortDuration } }

                    // Select on row click — sits underneath the delete button
                    MouseArea {
                        id: rowHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // Second click on the same row collapses the editor
                            if (root.editingVariantId === vid) {
                                root.editingVariantId = ""
                                root.editingVariant = null
                                return
                            }
                            const fresh = variants.find(v => v.id === vid) || null
                            if (fresh) root._selectVariant(fresh)
                        }
                    }

                    Row {
                        id: variantRow
                        anchors.left: parent.left
                        anchors.right: deleteBtn.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingS
                        spacing: Theme.spacingM

                        DankIcon {
                            name: vicon
                            size: Theme.iconSize
                            color: root.editingVariantId === vid ? Theme.onPrimaryContainer : Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            width: parent.width - Theme.iconSize - Theme.spacingM

                            StyledText {
                                text: vname || "Unnamed"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: root.editingVariantId === vid ? Theme.onPrimaryContainer : Theme.surfaceText
                                elide: Text.ElideRight
                                width: parent.width
                            }

                            StyledText {
                                text: vtext ? ("label: \"" + vtext + "\"") : "(no label)"
                                font.pixelSize: Theme.fontSizeSmall
                                color: root.editingVariantId === vid ? Theme.onPrimaryContainer : Theme.surfaceVariantText
                                elide: Text.ElideRight
                                width: parent.width
                            }
                        }
                    }

                    // Delete button — direct sibling with z:1 so it's above the row hover area
                    Rectangle {
                        id: deleteBtn
                        z: 1
                        width: 32; height: 32; radius: 16
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        color: delArea.containsMouse ? Theme.error : "transparent"

                        DankIcon {
                            anchors.centerIn: parent
                            name: "delete"; size: 16
                            color: delArea.containsMouse ? Theme.onError : Theme.surfaceVariantText
                        }

                        MouseArea {
                            id: delArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.editingVariantId === vid) {
                                    root.editingVariantId = ""
                                    root.editingVariant = null
                                }
                                removeVariant(vid)
                                ToastService.showInfo("Dropdown removed")
                            }
                        }
                    }
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // Section B — Item Editor
    // ════════════════════════════════════════════════════════════════════════

    StyledRect {
        width: parent.width
        height: itemEditorColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        visible: root.editingVariantId !== ""

        Column {
            id: itemEditorColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            // Editable variant metadata (root level only)
            StyledText {
                text: "Dropdown Settings"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                visible: root._atRoot
            }

            Row {
                width: parent.width
                spacing: Theme.spacingM
                visible: root._atRoot

                Column {
                    width: (parent.width - Theme.spacingM * 2) / 3
                    spacing: Theme.spacingXS
                    StyledText { text: "Icon"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                    DropdownIconPicker {
                        id: editIconPicker
                        width: parent.width
                        onIconSelected: (name) => root._saveVariantIcon(name)
                    }
                }

                Column {
                    width: (parent.width - Theme.spacingM * 2) / 3
                    spacing: Theme.spacingXS
                    StyledText { text: "Name"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                    DankTextField {
                        id: editNameField
                        width: parent.width
                        placeholderText: "Menu name"
                        onEditingFinished: root._saveVariantMeta()
                    }
                }

                Column {
                    width: (parent.width - Theme.spacingM * 2) / 3
                    spacing: Theme.spacingXS
                    StyledText { text: "Label"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                    DankTextField {
                        id: editLabelField
                        width: parent.width
                        placeholderText: "Bar pill text"
                        onEditingFinished: root._saveVariantMeta()
                    }
                }
            }

            // Bar pill display mode
            Row {
                spacing: Theme.spacingS
                visible: root._atRoot

                StyledText {
                    text: "Bar pill shows:"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }

                Repeater {
                    model: [
                        { value: "both", label: "Icon & Text" },
                        { value: "icon", label: "Icon only"  },
                        { value: "text", label: "Text only"  }
                    ]

                    delegate: DankButton {
                        required property var modelData
                        text: modelData.label
                        backgroundColor: root.editingPillDisplay === modelData.value
                            ? Theme.primary : Theme.surfaceContainerHigh
                        textColor: root.editingPillDisplay === modelData.value
                            ? Theme.onPrimary : Theme.surfaceText
                        buttonHeight: 32
                        onClicked: root._savePillDisplay(modelData.value)
                    }
                }
            }

            // ── Drilled-in sub-menu header (breadcrumb + rename) ──────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: !root._atRoot

                // Breadcrumb / back
                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    DankButton {
                        text: "Back"
                        iconName: "arrow_back"
                        buttonHeight: 32
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        onClicked: root._drillOut()
                    }

                    StyledText {
                        text: (root.editingVariant?.name || "Menu") + "  ›  " + (root.editingSubmenuLabel || "Sub-menu")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Theme.spacingS - 100
                    }
                }

                // Rename / re-icon this sub-menu
                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        StyledText { text: "Sub-menu icon"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        DropdownIconPicker {
                            id: submenuIconPicker
                            width: parent.width
                            currentIcon: "folder"
                            onIconSelected: (name) => root._saveSubmenuMeta()
                        }
                    }

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        StyledText { text: "Sub-menu name"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        DankTextField {
                            id: submenuNameField
                            width: parent.width
                            placeholderText: "Group name"
                            onEditingFinished: root._saveSubmenuMeta()
                        }
                    }
                }
            }

            // Current items
            StyledText {
                text: root._atRoot ? "Menu Items" : "Sub-menu Items"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceVariantText
            }

            StyledText {
                visible: root._currentItems().length === 0
                text: "No items yet. Add one below."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            ListView {
                id: itemsListView
                width: itemEditorColumn.width
                height: contentHeight
                model: localItemsModel
                interactive: false
                spacing: Theme.spacingS

                property int draggedIndex: -1
                property int dropIndex: -1

                function updateDropIndex(draggedIdx, localY) {
                    const totalItems = localItemsModel.count
                    let foundDropIndex = totalItems

                    for (let i = 0; i < totalItems; i++) {
                        const delegate = itemsListView.itemAtIndex(i)
                        if (!delegate) continue

                        const midpoint = delegate.y + delegate.height / 2
                        if (localY < midpoint) {
                            foundDropIndex = i
                            break
                        }
                    }

                    dropIndex = Math.max(0, Math.min(totalItems, foundDropIndex))
                    draggedIndex = draggedIdx
                }

                function finishDrag() {
                    if (draggedIndex < 0) {
                        dropIndex = -1
                        return
                    }

                    const fromIndex = draggedIndex
                    let toIndex = dropIndex

                    draggedIndex = -1
                    dropIndex = -1

                    if (toIndex < 0 || toIndex > localItemsModel.count || toIndex === fromIndex || toIndex === fromIndex + 1)
                        return

                    if (toIndex > fromIndex) toIndex -= 1

                    localItemsModel.move(fromIndex, toIndex, 1)
                    root._saveItems(root._currentItems())
                }

                move: Transition {
                    NumberAnimation { properties: "y"; duration: 200; easing.type: Easing.InOutQuad }
                }
                displaced: Transition {
                    NumberAnimation { properties: "y"; duration: 200; easing.type: Easing.InOutQuad }
                }

                // Drop indicator
                footer: Component {
                    Rectangle {
                        width: itemsListView.width
                        height: 2
                        color: Theme.primary
                        visible: itemsListView.draggedIndex >= 0 && itemsListView.dropIndex === localItemsModel.count
                    }
                }

                delegate: StyledRect {
                    id: itemDelegate
                    required property string itype
                    required property string iicon
                    required property string ilabel
                    required property string icommand
                    required property string ipluginId
                    required property string iwidgetId
                    required property string idisplay
                    required property string isubJson
                    required property int index

                    readonly property string _idRef: itype === "popout" ? iwidgetId : ipluginId
                    readonly property int _subCount: itype === "submenu"
                        ? JSON.parse(isubJson || "[]").length : 0

                    readonly property string resolvedIcon: iicon !== "" ? iicon
                        : (itype === "submenu" ? "folder"
                        : ((itype === "plugin" || itype === "popout" || itype === "embed") && pluginService
                            ? (pluginService.availablePlugins[_idRef]?.icon || "extension")
                            : "extension"))

                    readonly property string resolvedLabel: ilabel !== "" ? ilabel
                        : ((itype === "plugin" || itype === "popout" || itype === "embed") && pluginService
                            ? (pluginService.availablePlugins[_idRef]?.name || _idRef)
                            : "(no label)")

                    width: itemsListView.width
                    height: itemRow.implicitHeight + Theme.spacingS * 2
                    radius: Theme.cornerRadius
                    color: root.editingItemIndex === index
                        ? Theme.primaryContainer
                        : (editItemArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer)

                    Behavior on color { ColorAnimation { duration: Theme.shortDuration } }

                    Rectangle {
                        width: parent.width
                        height: 2
                        color: Theme.primary
                        anchors.top: parent.top
                        anchors.topMargin: -Theme.spacingS / 2
                        visible: itemsListView.draggedIndex >= 0 && itemsListView.dropIndex === index
                    }

                    opacity: itemsListView.draggedIndex === index ? 0.5 : 1.0

                    // Click the row (outside the reorder/remove buttons) to edit it
                    MouseArea {
                        id: editItemArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._editItem(index)
                    }

                    Row {
                        id: itemRow
                        anchors.left: parent.left
                        anchors.right: removeItemBtn.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingS

                        // Reorder handle
                        Rectangle {
                            width: 24; height: 32; radius: 4
                            color: reorderArea.pressed ? Theme.surfaceContainerHighest : "transparent"
                            anchors.verticalCenter: parent.verticalCenter

                            DankIcon {
                                anchors.centerIn: parent
                                name: "reorder"
                                size: 18
                                color: Theme.surfaceVariantText
                            }

                            MouseArea {
                                id: reorderArea
                                anchors.fill: parent
                                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                preventStealing: true

                                onPressed: (mouse) => {
                                    mouse.accepted = true
                                    const point = mapToItem(itemsListView, mouse.x, mouse.y)
                                    itemsListView.updateDropIndex(index, point.y)
                                }

                                onPositionChanged: (mouse) => {
                                    if (!pressed) return
                                    mouse.accepted = true
                                    const point = mapToItem(itemsListView, mouse.x, mouse.y)
                                    itemsListView.updateDropIndex(index, point.y)
                                }

                                onReleased: (mouse) => {
                                    mouse.accepted = true
                                    itemsListView.finishDrag()
                                }

                                onCanceled: {
                                    itemsListView.draggedIndex = -1
                                    itemsListView.dropIndex = -1
                                }
                            }
                        }

                        DankIcon {
                            name: resolvedIcon
                            size: Theme.iconSize - 4
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            width: parent.width - 24 - (Theme.iconSize - 4) - (parent.spacing * 2)

                            StyledText {
                                text: resolvedLabel
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                                width: parent.width
                            }

                            Row {
                                id: subtitleRow
                                width: parent.width
                                spacing: Theme.spacingXS

                                StyledRect {
                                    id: typeBadgeRect
                                    height: 18
                                    width: typeBadge.implicitWidth + 10
                                    radius: 9
                                    color: itype === "action" ? Theme.secondaryContainer : Theme.tertiaryContainer

                                    StyledText {
                                        id: typeBadge
                                        anchors.centerIn: parent
                                        text: itype
                                        font.pixelSize: 10
                                        color: Theme.surfaceText
                                        font.weight: Font.Bold
                                    }
                                }

                                StyledRect {
                                    id: displayBadgeRect
                                    height: 18
                                    width: displayBadge.implicitWidth + 10
                                    radius: 9
                                    color: Theme.surfaceContainerHighest

                                    StyledText {
                                        id: displayBadge
                                        anchors.centerIn: parent
                                        text: idisplay
                                        font.pixelSize: 10
                                        color: Theme.surfaceText
                                        font.weight: Font.Medium
                                    }
                                }

                                StyledText {
                                    width: subtitleRow.width - typeBadgeRect.width - displayBadgeRect.width - Theme.spacingXS * 2
                                    text: itype === "submenu"
                                        ? (_subCount + (_subCount === 1 ? " item" : " items") + " · click to open")
                                        : (itype === "action" ? icommand
                                        : (itype === "popout" ? iwidgetId : ipluginId))
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }

                    Rectangle {
                        id: removeItemBtn
                        width: 32; height: 32; radius: 16
                        color: removeItemArea.containsMouse ? Theme.error : "transparent"
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingS

                        DankIcon { anchors.centerIn: parent; name: "close"; size: 14; color: removeItemArea.containsMouse ? Theme.onError : Theme.surfaceVariantText }

                        MouseArea {
                            id: removeItemArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                const items = root._currentItems()
                                items.splice(index, 1)
                                root._saveItems(items)
                            }
                        }
                    }
                }
            }

            // Divider
            Rectangle {
                width: parent.width; height: 1
                color: Theme.outlineVariant; opacity: 0.5
            }

            // Quick Add — built-in panel shortcuts
            StyledText {
                text: "Quick Add"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceVariantText
            }

            StyledText {
                width: parent.width
                text: "Click a chip to pre-fill the form below — customize then click Add Item:"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            Flow {
                width: parent.width
                spacing: Theme.spacingS

                Repeater {
                    model: root.quickAddItems

                    delegate: Rectangle {
                        required property var modelData

                        readonly property bool alreadyAdded: {
                            // localItemsModel.count makes this binding reactive to list changes
                            for (let i = 0; i < localItemsModel.count; i++) {
                                if (localItemsModel.get(i).ipluginId === modelData.pluginId)
                                    return true
                            }
                            return false
                        }

                        height: 32
                        width: chipRow.implicitWidth + Theme.spacingM * 2
                        radius: height / 2
                        color: alreadyAdded
                            ? Theme.withAlpha(Theme.primary, 0.15)
                            : (chipArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer)
                        border.color: alreadyAdded ? Theme.primary : "transparent"
                        border.width: alreadyAdded ? 1 : 0

                        Behavior on color { ColorAnimation { duration: Theme.shortDuration } }

                        Row {
                            id: chipRow
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            DankIcon {
                                name: modelData.icon
                                size: 14
                                color: alreadyAdded ? Theme.primary : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeSmall
                                color: alreadyAdded ? Theme.primary : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            id: chipArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: alreadyAdded ? Qt.ArrowCursor : Qt.PointingHandCursor
                            enabled: !alreadyAdded
                            onClicked: {
                                // Add immediately with the chip's icon + default toggle action.
                                // Stays highlighted (alreadyAdded) until removed from the list.
                                const items = root._currentItems().slice()
                                items.push({
                                    type: "plugin",
                                    icon: modelData.icon,
                                    label: "",
                                    pluginId: modelData.pluginId,
                                    display: "both"
                                })
                                root._saveItems(items)
                                ToastService.showInfo(modelData.label + " added")
                            }
                        }
                    }
                }
            }

            // Divider before manual form
            Rectangle {
                width: parent.width; height: 1
                color: Theme.outlineVariant; opacity: 0.3
            }

            StyledText {
                text: root.editingItemIndex >= 0 ? "Edit Item" : "Add Item"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.editingItemIndex >= 0 ? Theme.primary : Theme.surfaceVariantText
            }

            // Type selector — use backgroundColor to show active state, no flat prop
            Flow {
                width: parent.width
                spacing: Theme.spacingS

                DankButton {
                    text: "Custom Action"
                    buttonHeight: 32
                    backgroundColor: root.newItemType === "action" ? Theme.primary : Theme.surfaceContainerHigh
                    textColor: root.newItemType === "action" ? Theme.onPrimary : Theme.surfaceText
                    onClicked: root.newItemType = "action"
                }

                DankButton {
                    text: "Plugin"
                    buttonHeight: 32
                    backgroundColor: root.newItemType === "plugin" ? Theme.primary : Theme.surfaceContainerHigh
                    textColor: root.newItemType === "plugin" ? Theme.onPrimary : Theme.surfaceText
                    // No auto IPC discovery — toggle/popout needs none, and
                    // `dms ipc --help` can crash the shell (see _detectPluginCommands).
                    onClicked: root.newItemType = "plugin"
                }

                DankButton {
                    text: "IPC Command"
                    buttonHeight: 32
                    backgroundColor: root.newItemType === "ipc" ? Theme.primary : Theme.surfaceContainerHigh
                    textColor: root.newItemType === "ipc" ? Theme.onPrimary : Theme.surfaceText
                    // Discovery is opt-in via the "Load IPC targets" button in the form.
                    onClicked: root.newItemType = "ipc"
                }

                // Sub-menus only nest one level, so this is hidden once drilled in.
                DankButton {
                    text: "Sub-menu"
                    iconName: "folder"
                    buttonHeight: 32
                    visible: root._atRoot
                    backgroundColor: root.newItemType === "submenu" ? Theme.primary : Theme.surfaceContainerHigh
                    textColor: root.newItemType === "submenu" ? Theme.onPrimary : Theme.surfaceText
                    onClicked: root.newItemType = "submenu"
                }
            }

            // Sub-menu fields — a group is just a label + icon; children are added
            // by creating it, then clicking it in the list to drill in.
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.newItemType === "submenu"

                StyledText {
                    width: parent.width
                    text: "Create an empty group, then click it in the list above to add items inside it."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        StyledText { text: "Icon (optional)"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        DropdownIconPicker {
                            id: submenuFormIcon
                            width: parent.width
                            currentIcon: ""
                            onIconSelected: (name) => root.newItemIcon = name
                        }
                    }

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        StyledText { text: "Name"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        DankTextField {
                            id: submenuFormLabel
                            width: parent.width
                            placeholderText: "e.g. Power, Media…"
                            onTextChanged: root.newItemLabel = text
                        }
                    }
                }
            }

            // Action fields
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.newItemType === "action"

                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        Row {
                            StyledText { text: "Icon (optional)"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        }
                        DropdownIconPicker {
                            id: actionIconField
                            width: parent.width
                            currentIcon: ""
                            onIconSelected: (name) => root.newItemIcon = name
                        }
                    }

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        StyledText { text: "Label"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        DankTextField {
                            id: actionLabelField
                            width: parent.width
                            placeholderText: "Terminal"
                            onTextChanged: root.newItemLabel = text
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    StyledText { text: "Shell Command"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                    DankTextField {
                        id: actionCommandField
                        width: parent.width
                        placeholderText: "kitty --hold"
                        onTextChanged: root.newItemCommand = text
                    }
                }
            }

            // Plugin fields
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.newItemType === "plugin"

                StyledText { text: "Plugin"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }

                DankDropdown {
                    id: pluginPicker
                    width: parent.width
                    options: root.availablePluginNames
                    onValueChanged: (value) => {
                        const idx = root.availablePluginNames.indexOf(value)
                        if (idx >= 0) {
                            root.newItemPluginId = root.availablePluginList[idx].id
                            root._detectPluginCommands(root.newItemPluginId)
                        }
                    }
                }

                StyledText {
                    visible: {
                        root._pluginStateRev
                        return root.newItemPluginId !== ""
                            && (root.availablePluginList.find(p => p.id === root.newItemPluginId) || {}).isPlugin
                            && !root._pluginEnabled(root.newItemPluginId)
                    }
                    width: parent.width
                    text: "⚠ This plugin isn't enabled — enable it in Settings → Plugins for any action to work."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.error
                    wrapMode: Text.WordWrap
                }

                // What the item does: toggle / open popout / embed live / a detected IPC action
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.newItemPluginId !== ""

                    StyledText {
                        text: {
                            if (root.pluginScanning)
                                return "Detecting available actions…"
                            const n = root.pluginCommandOptions.length
                            const base = root._selectedIsWidget ? "open popout" : "toggle / open"
                            return n > 0
                                ? "Action  (" + n + " IPC action" + (n === 1 ? "" : "s") + " detected — or " + base + ")"
                                : "Action  (no IPC actions detected — use " + base + ")"
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }

                    DankDropdown {
                        id: pluginCommandPicker
                        width: parent.width
                        enabled: !root.pluginScanning
                        emptyText: ""
                        options: root.pluginActionOptions.map(o => o.label)
                        onValueChanged: (value) => {
                            const opt = root.pluginActionOptions.find(o => o.label === value)
                            if (!opt) {
                                const def = root.pluginActionOptions[0]
                                root.newPluginActionKind = def ? def.kind : "toggle"
                                root.newPluginCmdTarget = ""
                                root.newPluginCmdFn = ""
                                return
                            }
                            root.newPluginActionKind = opt.kind
                            root.newPluginCmdTarget = opt.target || ""
                            root.newPluginCmdFn = opt.fn || ""
                        }
                    }

                    // Opt-in IPC-action discovery. Left off by default because
                    // `dms ipc --help` enumerates every handler and can crash the
                    // shell (upstream quickshell wireDef segfault). Toggle/open
                    // needs none of this.
                    DankButton {
                        visible: root.newItemPluginId !== "" && !root.ipcLoaded
                        text: root.ipcLoading ? "Scanning…" : "Detect IPC actions…"
                        iconName: "search"
                        buttonHeight: 32
                        enabled: !root.ipcLoading
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        onClicked: root._loadIpcTargets()
                    }

                    StyledText {
                        visible: root.newItemPluginId !== "" && !root.ipcLoaded && !root.ipcLoading
                        width: parent.width
                        text: "Optional — scans DMS IPC targets so this plugin's IPC actions can be offered. Skip it if you only need toggle / open. ⚠ On some setups IPC discovery can crash the shell (a known quickshell bug)."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }

                    StyledText {
                        visible: {
                            root._pluginStateRev
                            return root.newPluginActionKind === "popout" && root.newItemPluginId !== ""
                                && root._pluginEnabled(root.newItemPluginId)
                                && !root._pluginOnBar(root.newItemPluginId)
                        }
                        width: parent.width
                        text: "This plugin isn't on a bar — the dropdown runs it in the background to open its popout on demand."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }

                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        StyledText { text: "Icon override (optional)"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        DropdownIconPicker {
                            id: pluginIconField
                            width: parent.width
                            currentIcon: ""
                            onIconSelected: (name) => root.newItemIcon = name
                        }
                    }

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        StyledText { text: "Label override (optional)"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        DankTextField {
                            id: pluginLabelField
                            width: parent.width
                            placeholderText: "leave blank for plugin default"
                            onTextChanged: root.newItemLabel = text
                        }
                    }
                }
            }

            // IPC fields
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.newItemType === "ipc"

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        text: "Run a DMS IPC command. Many plugins register actions here (e.g. pomodoroTimer → startWork)."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        width: parent.width - refreshIpcBtn.width - Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // Loading is user-initiated: `dms ipc --help` enumerates every
                    // handler and can crash the shell (upstream wireDef segfault).
                    DankButton {
                        id: refreshIpcBtn
                        text: root.ipcLoading ? "Loading…" : (root.ipcLoaded ? "Refresh" : "Load IPC targets")
                        iconName: "refresh"
                        buttonHeight: 32
                        enabled: !root.ipcLoading
                        onClicked: root._loadIpcTargets()
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                StyledText {
                    visible: !root.ipcLoaded && !root.ipcLoading
                    width: parent.width
                    text: "Click “Load IPC targets” to list available commands. ⚠ Discovery scans all IPC handlers and can crash the shell on some setups (a known quickshell bug). Already know the command? You can add it as a Custom Action instead (e.g. dms ipc <target> <function>)."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        StyledText { text: "Target"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        DankDropdown {
                            id: ipcTargetPicker
                            width: parent.width
                            emptyText: root.ipcLoaded ? "Select target…" : (root.ipcLoading ? "Loading…" : "Load targets first")
                            options: root.ipcTargetNames
                            onValueChanged: (value) => {
                                root.newItemIpcTarget = value
                                root.newItemIpcFunction = ""
                                ipcFunctionPicker.currentValue = ""
                            }
                        }
                    }

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        StyledText { text: "Function"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        DankDropdown {
                            id: ipcFunctionPicker
                            width: parent.width
                            emptyText: root.newItemIpcTarget ? "Select function…" : "Pick target first"
                            options: root.ipcFunctionsForTarget
                            enabled: root.newItemIpcTarget !== ""
                            onValueChanged: (value) => root.newItemIpcFunction = value
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    StyledText { text: "Arguments (optional — most actions need none)"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                    DankTextField {
                        id: ipcArgsField
                        width: parent.width
                        placeholderText: "e.g. 50"
                        onTextChanged: root.newItemIpcArgs = text
                    }
                }

                // Live command preview
                StyledRect {
                    width: parent.width
                    height: ipcPreviewText.implicitHeight + Theme.spacingM
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainer
                    visible: root.ipcCommandPreview !== ""

                    StyledText {
                        id: ipcPreviewText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingM
                        text: "$ " + root.ipcCommandPreview
                        font.family: "monospace"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        wrapMode: Text.WrapAnywhere
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingM

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        StyledText { text: "Icon (optional)"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        DropdownIconPicker {
                            id: ipcIconField
                            width: parent.width
                            currentIcon: ""
                            onIconSelected: (name) => root.newItemIcon = name
                        }
                    }

                    Column {
                        width: (parent.width - Theme.spacingM) / 2
                        spacing: Theme.spacingXS
                        StyledText { text: "Label (optional)"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                        DankTextField {
                            id: ipcLabelField
                            width: parent.width
                            placeholderText: root.newItemIpcTarget && root.newItemIpcFunction
                                ? (root.newItemIpcTarget + ": " + root.newItemIpcFunction)
                                : "auto from target/function"
                            onTextChanged: root.newItemLabel = text
                        }
                    }
                }
            }

            // Display mode — shared by all forms
            Row {
                spacing: Theme.spacingS

                StyledText {
                    text: "Show in menu:"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }

                Repeater {
                    model: [
                        { value: "both", label: "Icon & Text" },
                        { value: "icon", label: "Icon only"  },
                        { value: "text", label: "Text only"  }
                    ]

                    delegate: DankButton {
                        required property var modelData
                        text: modelData.label
                        backgroundColor: root.newItemDisplay === modelData.value
                            ? Theme.primary : Theme.surfaceContainerHigh
                        textColor: root.newItemDisplay === modelData.value
                            ? Theme.onPrimary : Theme.surfaceText
                        buttonHeight: 32
                        onClicked: root.newItemDisplay = modelData.value
                    }
                }
            }

            Row {
                spacing: Theme.spacingS

                DankButton {
                    text: root.editingItemIndex >= 0 ? "Update Item" : "Add Item"
                    iconName: root.editingItemIndex >= 0 ? "check" : "add"
                    onClicked: {
                        let newItem = null
                        if (root.newItemType === "submenu") {
                            if (!root.newItemLabel) {
                                ToastService.showError("Please enter a name for the sub-menu")
                                return
                            }
                            newItem = {
                                type: "submenu",
                                icon: root.newItemIcon,
                                label: root.newItemLabel,
                                display: root.newItemDisplay,
                                items: []   // children added by drilling in
                            }
                        } else if (root.newItemType === "action") {
                            if (!root.newItemCommand) {
                                ToastService.showError("Please enter a shell command")
                                return
                            }
                            if (!root.newItemLabel) {
                                ToastService.showError("Please enter a label")
                                return
                            }
                            newItem = {
                                type: "action",
                                icon: root.newItemIcon,
                                label: root.newItemLabel,
                                command: root.newItemCommand,
                                display: root.newItemDisplay
                            }
                            // Preserve the owning plugin of a plugin-sourced IPC action
                            // through an edit so the widget keeps hosting it.
                            if (root.newItemActionPluginId)
                                newItem.pluginId = root.newItemActionPluginId
                        } else if (root.newItemType === "ipc") {
                            if (!root.newItemIpcTarget || !root.newItemIpcFunction) {
                                ToastService.showError("Please select an IPC target and function")
                                return
                            }
                            newItem = {
                                type: "action",
                                icon: root.newItemIcon,
                                label: root.newItemLabel || (root.newItemIpcTarget + ": " + root.newItemIpcFunction),
                                command: root.ipcCommandPreview,
                                display: root.newItemDisplay
                            }
                        } else {
                            if (!root.newItemPluginId) {
                                ToastService.showError("Please select a plugin")
                                return
                            }
                            const pName = (root.availablePluginList.find(p => p.id === root.newItemPluginId) || {}).name || root.newItemPluginId
                            if (root.newPluginActionKind === "ipc" && root.newPluginCmdFn) {
                                newItem = {
                                    type: "action",
                                    icon: root.newItemIcon,
                                    label: root.newItemLabel || (pName + ": " + root.newPluginCmdFn),
                                    command: "dms ipc " + root.newPluginCmdTarget + " " + root.newPluginCmdFn,
                                    pluginId: root.newItemPluginId,
                                    display: root.newItemDisplay
                                }
                            } else if (root.newPluginActionKind === "popout") {
                                newItem = {
                                    type: "popout",
                                    icon: root.newItemIcon,
                                    label: root.newItemLabel,
                                    widgetId: root.newItemPluginId,
                                    display: root.newItemDisplay
                                }
                            } else {
                                newItem = {
                                    type: "plugin",
                                    icon: root.newItemIcon,
                                    label: root.newItemLabel,
                                    pluginId: root.newItemPluginId,
                                    display: root.newItemDisplay
                                }
                            }
                        }

                        const items = root._currentItems().slice()
                        const wasEditing = root.editingItemIndex >= 0 && root.editingItemIndex < items.length
                        if (wasEditing)
                            items[root.editingItemIndex] = newItem
                        else
                            items.push(newItem)
                        root._saveItems(items)
                        root._resetItemForm()
                        ToastService.showInfo(wasEditing ? "Item updated" : "Item added")
                    }
                }

                DankButton {
                    visible: root.editingItemIndex >= 0
                    text: "Cancel"
                    backgroundColor: Theme.surfaceContainerHigh
                    textColor: Theme.surfaceText
                    onClicked: root._resetItemForm()
                }
            }
        }
    }

}
