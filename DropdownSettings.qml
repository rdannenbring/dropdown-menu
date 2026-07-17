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

    // The item list shows the whole tree at once (unified indented view). The
    // canonical data is editingVariant.items (nested JS); localItemsModel is a
    // flat *projection* of it. Sub-menu folders expand/collapse in the editor
    // via editorExpanded, keyed by the folder's root index.
    property var editorExpanded: ({})
    // Where the next added item lands: -1 = top level, >=0 = that root folder.
    property int addTargetParent: -1
    // Position within the target level for the next add: -1 = append, >=0 =
    // insert before that index (set by the hover-to-insert "+" between rows).
    property int addTargetPos: -1
    // Folders (root-level sub-menus), for the per-row "Move to" chooser.
    readonly property var _folders: {
        const out = []
        const items = editingVariant?.items ?? []
        for (let i = 0; i < items.length; i++)
            if (items[i]?.type === "submenu")
                out.push({ index: i, label: items[i].label || ("Folder " + (i + 1)) })
        return out
    }

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
    property string newVariantPill: "both"

    // Unsaved-changes guard: snapshot the form on open, compare on close-attempt.
    property string _confirmTarget: ""       // "item" | "create"
    property string _itemOpenSnapshot: ""
    property string _createOpenSnapshot: ""

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
    // Path of the item being edited: parent = -1 (top level) or a folder's root
    // index; pos = index within that level. pos < 0 means "adding new".
    property int editingParent: -1
    property int editingPos: -1
    readonly property bool _isEditing: editingPos >= 0

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

    // ── Flat projection of the nested tree ───────────────────────────────────
    // localItemsModel holds one row per visible item across the whole tree, each
    // tagged with its path: rDepth (0/1), rParent (folder root index or -1),
    // rPos (index within its level). Sub-menu children only appear when that
    // folder is expanded in the editor. Deeper nesting would recurse here.
    // grp/top/bot mark rows that belong to an expanded folder's shaded band
    // (the header + its children), and which row is the band's top/bottom edge.
    function _appendRow(it, depth, parent, pos, grp, top, bot) {
        localItemsModel.append({
            itype:     it.type      || "action",
            iicon:     it.icon      || "",
            ilabel:    it.label     || "",
            icommand:  it.command   || "",
            ipluginId: it.pluginId  || "",
            iwidgetId: it.widgetId  || "",
            idisplay:  it.display   || "both",
            isubJson:  JSON.stringify(it.items || []),
            rDepth: depth, rParent: parent, rPos: pos,
            rGroupBg: grp === true, rGroupTop: top === true, rGroupBottom: bot === true
        })
    }

    function _syncItemsModel() {
        localItemsModel.clear()
        const items = editingVariant?.items ?? []
        for (let ri = 0; ri < items.length; ri++) {
            const it = items[ri]
            const expanded = it && it.type === "submenu" && !!editorExpanded[ri]
            const kids = expanded ? (it.items || []) : []
            _appendRow(it, 0, -1, ri, expanded, expanded, expanded && kids.length === 0)
            for (let ci = 0; ci < kids.length; ci++)
                _appendRow(kids[ci], 1, ri, ci, true, false, ci === kids.length - 1)
        }
    }

    // ── Tree mutation (clone → edit by path → commit → re-project) ────────────
    function _cloneTree() { return JSON.parse(JSON.stringify(editingVariant?.items ?? [])) }

    function _commitTree(tree) {
        if (!editingVariantId || !pluginService) return
        updateVariant(editingVariantId, { items: tree })
        editingVariant = Object.assign({}, editingVariant, { items: tree })
        _syncItemsModel()
    }

    // The items array for a level in `tree`: root (parent<0) or a folder's items.
    function _levelOf(tree, parent) {
        if (parent < 0) return tree
        const f = tree[parent]
        if (!f.items) f.items = []
        return f.items
    }

    // editorExpanded is keyed by root index, so removing a root item shifts keys.
    function _expandedAfterRootRemove(removed) {
        const out = {}
        for (const k in editorExpanded) {
            if (!editorExpanded[k]) continue
            const i = parseInt(k)
            if (i < removed) out[i] = true
            else if (i > removed) out[i - 1] = true
        }
        return out
    }

    function _addItemAt(parent, item) {
        const tree = _cloneTree()
        _levelOf(tree, parent).push(item)
        if (parent >= 0) { const m = Object.assign({}, editorExpanded); m[parent] = true; editorExpanded = m }
        _commitTree(tree)
    }

    // Inserting a root item shifts folder root indices >= pos up by one.
    function _expandedAfterRootInsert(insertedAt) {
        const out = {}
        for (const k in editorExpanded) {
            if (!editorExpanded[k]) continue
            const i = parseInt(k)
            out[i < insertedAt ? i : i + 1] = true
        }
        return out
    }

    // Insert an item at a specific position within a level (hover-to-insert).
    function _insertItemAt(parent, pos, item) {
        const tree = _cloneTree()
        const lvl = _levelOf(tree, parent)
        if (pos < 0 || pos > lvl.length) lvl.push(item)
        else lvl.splice(pos, 0, item)
        if (parent < 0) editorExpanded = _expandedAfterRootInsert(pos)
        else { const m = Object.assign({}, editorExpanded); m[parent] = true; editorExpanded = m }
        _commitTree(tree)
    }

    // Open the add dialog to APPEND to a level (top-level button / folder "+").
    function _openAddDialog(parent) {
        _resetItemForm()
        addTargetParent = parent
        addTargetPos = -1
        if (parent >= 0) { const m = Object.assign({}, editorExpanded); m[parent] = true; editorExpanded = m; _syncItemsModel() }
        addItemPopup.open()
    }

    // Open the add dialog to INSERT before (parent, pos) — the between-rows "+".
    function _openInsertDialog(parent, pos) {
        _resetItemForm()
        addTargetParent = parent
        addTargetPos = pos
        if (parent >= 0) { const m = Object.assign({}, editorExpanded); m[parent] = true; editorExpanded = m; _syncItemsModel() }
        addItemPopup.open()
    }

    function _updateItemAt(parent, pos, item) {
        const tree = _cloneTree()
        const lvl = _levelOf(tree, parent)
        if (pos < 0 || pos >= lvl.length) return
        // Editing a folder's meta shouldn't drop its children.
        if (item.type === "submenu" && item.items === undefined
            && lvl[pos] && lvl[pos].type === "submenu")
            item.items = lvl[pos].items || []
        lvl[pos] = item
        _commitTree(tree)
    }

    function _removeItemAt(parent, pos) {
        const tree = _cloneTree()
        const lvl = _levelOf(tree, parent)
        if (pos < 0 || pos >= lvl.length) return
        lvl.splice(pos, 1)
        if (parent < 0) editorExpanded = _expandedAfterRootRemove(pos)
        _commitTree(tree)
    }

    function _reorderWithinLevel(parent, fromPos, toPos) {
        const tree = _cloneTree()
        const lvl = _levelOf(tree, parent)
        if (fromPos < 0 || fromPos >= lvl.length) return
        if (toPos < 0) toPos = 0
        if (toPos > lvl.length) toPos = lvl.length
        if (toPos === fromPos || toPos === fromPos + 1) return
        // Track folder expansion across a root-level reorder.
        let flags = null
        if (parent < 0) flags = lvl.map((_, i) => !!editorExpanded[i])
        let insert = toPos
        const moved = lvl.splice(fromPos, 1)[0]
        if (insert > fromPos) insert -= 1
        lvl.splice(insert, 0, moved)
        if (flags) {
            const mf = flags.splice(fromPos, 1)[0]
            flags.splice(insert, 0, mf)
            const m = {}; flags.forEach((f, i) => { if (f) m[i] = true }); editorExpanded = m
        }
        _commitTree(tree)
    }

    // Move an item to the end of another level. One level: a folder can't be
    // moved into a folder. Capture the destination array *before* splicing the
    // source (object refs stay valid; the folder's root index may shift).
    function _moveItem(fromParent, fromPos, destParent) {
        if (fromParent === destParent) return
        const tree = _cloneTree()
        const destLevel = _levelOf(tree, destParent)
        const src = _levelOf(tree, fromParent)
        if (fromPos < 0 || fromPos >= src.length) return
        const moving = src[fromPos]
        if (moving.type === "submenu" && destParent >= 0) return
        src.splice(fromPos, 1)
        destLevel.push(moving)
        let newDest = destParent
        if (fromParent < 0) {
            editorExpanded = _expandedAfterRootRemove(fromPos)
            if (destParent >= 0 && fromPos < destParent) newDest = destParent - 1
        }
        if (newDest >= 0) { const m = Object.assign({}, editorExpanded); m[newDest] = true; editorExpanded = m }
        _commitTree(tree)
    }

    function _toggleEditorExpand(rootIndex) {
        const m = Object.assign({}, editorExpanded)
        m[rootIndex] = !m[rootIndex]
        editorExpanded = m
        _syncItemsModel()
    }

    function _resetCreateForm() {
        newVariantName = ""
        newVariantIcon = "expand_circle_down"
        newVariantText = ""
        newVariantPill = "both"
        variantNameField.text = ""
        variantTextField.text = ""
        variantIconField.currentIcon = "expand_circle_down"
    }

    // ── Dialog save + unsaved-changes handling ───────────────────────────────
    function _itemFormSnapshot() {
        return JSON.stringify([newItemType, newItemIcon, newItemLabel, newItemCommand,
            newItemPluginId, newItemActionPluginId, newItemDisplay, newPluginActionKind,
            newPluginCmdTarget, newPluginCmdFn, newItemIpcTarget, newItemIpcFunction, newItemIpcArgs])
    }
    function _createFormSnapshot() {
        return JSON.stringify([newVariantName, newVariantIcon, newVariantText, newVariantPill])
    }
    // Outside-click / close request: prompt only if the form changed since open.
    function _tryCloseItemDialog() {
        if (_itemFormSnapshot() !== _itemOpenSnapshot) { _confirmTarget = "item"; confirmPopup.open() }
        else addItemPopup.close()
    }
    function _tryCloseCreateDialog() {
        if (_createFormSnapshot() !== _createOpenSnapshot) { _confirmTarget = "create"; confirmPopup.open() }
        else createDropdownPopup.close()
    }

    // Build + persist the item form; on validation failure it toasts and leaves
    // the dialog open (early return). Shared by the dialog's button and the
    // unsaved-changes "Save".
    function _commitItemForm() {
        let newItem = null
        if (newItemType === "submenu") {
            if (!newItemLabel) { ToastService.showError("Please enter a name for the sub-menu"); return }
            newItem = { type: "submenu", icon: newItemIcon, label: newItemLabel, display: newItemDisplay }
        } else if (newItemType === "action") {
            if (!newItemCommand) { ToastService.showError("Please enter a shell command"); return }
            if (!newItemLabel) { ToastService.showError("Please enter a label"); return }
            newItem = { type: "action", icon: newItemIcon, label: newItemLabel, command: newItemCommand, display: newItemDisplay }
            if (newItemActionPluginId) newItem.pluginId = newItemActionPluginId
        } else if (newItemType === "ipc") {
            if (!newItemIpcTarget || !newItemIpcFunction) { ToastService.showError("Please select an IPC target and function"); return }
            newItem = { type: "action", icon: newItemIcon, label: newItemLabel || (newItemIpcTarget + ": " + newItemIpcFunction), command: ipcCommandPreview, display: newItemDisplay }
        } else {
            if (!newItemPluginId) { ToastService.showError("Please select a plugin"); return }
            const pName = (availablePluginList.find(p => p.id === newItemPluginId) || {}).name || newItemPluginId
            if (newPluginActionKind === "ipc" && newPluginCmdFn) {
                newItem = { type: "action", icon: newItemIcon, label: newItemLabel || (pName + ": " + newPluginCmdFn), command: "dms ipc " + newPluginCmdTarget + " " + newPluginCmdFn, pluginId: newItemPluginId, display: newItemDisplay }
            } else if (newPluginActionKind === "popout") {
                newItem = { type: "popout", icon: newItemIcon, label: newItemLabel, widgetId: newItemPluginId, display: newItemDisplay }
            } else {
                newItem = { type: "plugin", icon: newItemIcon, label: newItemLabel, pluginId: newItemPluginId, display: newItemDisplay }
            }
        }
        const wasEditing = _isEditing
        if (wasEditing) _updateItemAt(editingParent, editingPos, newItem)
        else if (addTargetPos >= 0) _insertItemAt(addTargetParent, addTargetPos, newItem)
        else _addItemAt(addTargetParent, newItem)
        _resetItemForm()
        addItemPopup.close()
        ToastService.showInfo(wasEditing ? "Item updated" : "Item added")
    }

    function _commitCreateForm() {
        const nm = newVariantName.trim()
        if (!nm) { ToastService.showError("Please enter a name for the dropdown"); return }
        const cfg = { icon: newVariantIcon || "expand_circle_down", text: newVariantText, pillDisplay: newVariantPill, items: [] }
        const newId = createVariant(nm, cfg)
        if (!newId) { ToastService.showError("Failed to save — plugin service unavailable"); return }
        Qt.callLater(() => pluginService.reloadPlugin("dropdownMenu"))
        _selectVariant({ id: newId, name: nm, icon: cfg.icon, text: cfg.text, pillDisplay: cfg.pillDisplay, items: [] })
        ToastService.showInfo("Dropdown created: " + nm)
        createDropdownPopup.close()
    }

    function _selectVariant(variant) {
        editingVariantId = variant.id
        editingVariant = variant
        editingPillDisplay = variant.pillDisplay || "both"
        editorExpanded = ({})       // start collapsed
        addTargetParent = -1        // add to top level by default
        addTargetPos = -1
        _syncItemsModel()
        // Populate the meta-edit fields
        editNameField.text = variant.name || ""
        editLabelField.text = variant.text || ""
        editIconPicker.currentIcon = variant.icon || "expand_circle_down"
        // Reset the add-item form
        _resetItemForm()
    }

    function _resetItemForm() {
        editingParent = -1
        editingPos = -1
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
        _resetItemForm()
        editingParent = r.rParent
        editingPos = r.rPos
        newItemDisplay = r.idisplay || "both"
        newItemIcon = r.iicon || ""
        newItemLabel = r.ilabel || ""
        if (r.itype === "submenu") {
            // Edit the folder's own name/icon (children stay put); Update writes
            // meta only and _updateItemAt preserves items.
            newItemType = "submenu"
            submenuFormIcon.currentIcon = r.iicon || ""
            submenuFormLabel.text = r.ilabel || ""
        } else if (r.itype === "action") {
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
                text: "1. Create a dropdown above, then click it to edit (click again to collapse)\n2. Click “Add item…” (or a folder’s +) to open the editor dialog — pick a type or a Quick Add chip, then Add Item\n3. Group items with a Sub-menu (folder); drag the handle to reorder within a level, or “Move to” to shift an item into a folder\n4. Click any item to edit it; ✕ to remove\n5. The bar pill can show an icon, text, or both (set in the editor)\n6. Go to Bar Settings → Add Widget to place the dropdown on your bar\n\nClicking the dropdown on the bar opens/closes its menu."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                lineHeight: 1.5
            }
        }
    }

    // Create dropdown — a compact card whose button opens the editor dialog.
    StyledRect {
        width: parent.width
        height: createRow.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Row {
            id: createRow
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Add a new dropdown, set its bar pill, then add items to it."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                width: parent.width - createBtn.width - Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                wrapMode: Text.WordWrap
            }

            DankButton {
                id: createBtn
                text: "Create Dropdown"
                iconName: "add"
                anchors.verticalCenter: parent.verticalCenter
                onClicked: { root._resetCreateForm(); createDropdownPopup.open() }
            }
        }

        // ── Create dropdown dialog ───────────────────────────────────────────
        Popup {
            id: createDropdownPopup
            parent: Overlay.overlay
            modal: true
            dim: false
            padding: 0
            closePolicy: Popup.CloseOnEscape
            x: 0
            y: 0
            width: Overlay.overlay?.width ?? 900
            height: Overlay.overlay?.height ?? 800
            onOpened: root._createOpenSnapshot = root._createFormSnapshot()

            background: Rectangle { color: "transparent" }

            contentItem: Item {
                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(0, 0, 0, 0.45)
                    MouseArea { anchors.fill: parent; onClicked: root._tryCloseCreateDialog() }
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: Math.min(520, parent.width - 80)
                    height: createForm.implicitHeight + Theme.spacingL * 2
                    color: Theme.surface
                    radius: Theme.cornerRadius

                    MouseArea { anchors.fill: parent }   // absorb clicks on the card

                    Column {
                        id: createForm
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingL
                        spacing: Theme.spacingM

                    StyledText {
                        text: "New dropdown"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        Column {
                            width: 120
                            spacing: Theme.spacingXS
                            StyledText { text: "Icon"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                            DropdownIconPicker {
                                id: variantIconField
                                width: parent.width
                                currentIcon: "expand_circle_down"
                                onIconSelected: (name) => root.newVariantIcon = name
                            }
                        }

                        Column {
                            width: parent.width - 120 - Theme.spacingM
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
                                text: "Shown in the Add Widget picker"
                                font.pixelSize: 10
                                color: Theme.surfaceVariantText
                                opacity: 0.7
                                wrapMode: Text.WordWrap
                            }
                        }
                    }

                    Column {
                        width: parent.width
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
                            text: "Text on the bar pill (leave blank for icon only)"
                            font.pixelSize: 10
                            color: Theme.surfaceVariantText
                            opacity: 0.7
                            wrapMode: Text.WordWrap
                        }
                    }

                    // Bar pill display
                    Row {
                        spacing: Theme.spacingS

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
                                buttonHeight: 32
                                backgroundColor: root.newVariantPill === modelData.value ? Theme.primary : Theme.surfaceContainerHigh
                                textColor: root.newVariantPill === modelData.value ? Theme.onPrimary : Theme.surfaceText
                                onClicked: root.newVariantPill = modelData.value
                            }
                        }
                    }

                    // Actions
                    Row {
                        spacing: Theme.spacingS

                        DankButton {
                            text: "Create Dropdown"
                            iconName: "add"
                            onClicked: root._commitCreateForm()
                        }

                        DankButton {
                            text: "Cancel"
                            backgroundColor: Theme.surfaceContainerHigh
                            textColor: Theme.surfaceText
                            onClicked: createDropdownPopup.close()
                        }
                    }
                }
                }
            }
        }

        // ── Unsaved-changes confirmation (shared by both dialogs) ────────────
        Popup {
            id: confirmPopup
            parent: Overlay.overlay
            modal: true
            dim: true
            padding: 0
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

            readonly property real _ow: Overlay.overlay?.width ?? 900
            readonly property real _oh: Overlay.overlay?.height ?? 800
            width: Math.min(420, _ow - 80)
            height: confirmCol.implicitHeight + Theme.spacingL * 2
            x: (_ow - width) / 2
            y: (_oh - height) / 2

            background: Rectangle { color: "transparent" }

            contentItem: Rectangle {
                color: Theme.surface
                radius: Theme.cornerRadius

                Column {
                    id: confirmCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    StyledText {
                        text: "Unsaved changes"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        text: "You have unsaved changes. Save them, discard them, or keep editing?"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        DankButton {
                            text: "Save"
                            iconName: "check"
                            onClicked: {
                                if (root._confirmTarget === "item") root._commitItemForm()
                                else root._commitCreateForm()
                                confirmPopup.close()
                            }
                        }

                        DankButton {
                            text: "Discard"
                            backgroundColor: Theme.surfaceContainerHigh
                            textColor: Theme.error
                            onClicked: {
                                if (root._confirmTarget === "item") addItemPopup.close()
                                else createDropdownPopup.close()
                                confirmPopup.close()
                            }
                        }

                        DankButton {
                            text: "Keep editing"
                            backgroundColor: Theme.surfaceContainerHigh
                            textColor: Theme.surfaceText
                            onClicked: confirmPopup.close()
                        }
                    }
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

            // Editable variant metadata
            StyledText {
                text: "Dropdown Settings"
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

            // Current items
            StyledText {
                text: "Menu Items"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceVariantText
            }

            StyledText {
                width: parent.width
                text: "Folders show their items indented below. Use the chevron to fold a group, the reorder handle to move within a level, or “Move to” to shift an item into a folder."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            // Primary add action, at the top of the list.
            DankButton {
                text: "Add item…"
                iconName: "add"
                onClicked: root._openAddDialog(-1)
            }

            StyledText {
                visible: localItemsModel.count === 0
                text: "No items yet. Click “Add item…”."
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

                // Sibling-aware drag: a drag only reorders items within the level
                // (top level or one folder) the dragged row belongs to. Cross-level
                // moves are the per-row "Move to" control, not drag (v1).
                property int draggedIndex: -1     // projection index being dragged
                property int draggedParent: -2    // its level: -1 top, >=0 folder
                property int draggedPos: -1       // its position within that level
                property int dropPos: -1          // target position within the level
                property int dropAboveProj: -1    // draw indicator above this row; -1 = append
                property int dropLastSibProj: -1  // last sibling row (append line)

                function updateDropIndex(draggedProjIdx, localY) {
                    const dr = localItemsModel.get(draggedProjIdx)
                    if (!dr) return
                    const parent = dr.rParent
                    let aboveProj = -1
                    let targetPos = 0
                    let lastSibProj = -1
                    let sibCount = 0
                    for (let i = 0; i < localItemsModel.count; i++) {
                        const r = localItemsModel.get(i)
                        if (r.rParent !== parent) continue   // only siblings of the dragged row
                        lastSibProj = i
                        sibCount++
                        if (aboveProj === -1) {
                            const del = itemsListView.itemAtIndex(i)
                            if (del && localY < del.y + del.height / 2) {
                                aboveProj = i
                                targetPos = r.rPos
                            }
                        }
                    }
                    if (aboveProj === -1) targetPos = sibCount   // past the last sibling
                    draggedIndex = draggedProjIdx
                    draggedParent = parent
                    draggedPos = dr.rPos
                    dropPos = targetPos
                    dropAboveProj = aboveProj
                    dropLastSibProj = lastSibProj
                }

                function finishDrag() {
                    const parent = draggedParent
                    const from = draggedPos
                    const to = dropPos
                    draggedIndex = -1; draggedParent = -2; draggedPos = -1
                    dropPos = -1; dropAboveProj = -1; dropLastSibProj = -1
                    if (from < 0) return
                    root._reorderWithinLevel(parent, from, to)
                }

                move: Transition {
                    NumberAnimation { properties: "y"; duration: 200; easing.type: Easing.InOutQuad }
                }
                displaced: Transition {
                    NumberAnimation { properties: "y"; duration: 200; easing.type: Easing.InOutQuad }
                }

                delegate: Item {
                    id: itemDelegate
                    required property string itype
                    required property string iicon
                    required property string ilabel
                    required property string icommand
                    required property string ipluginId
                    required property string iwidgetId
                    required property string idisplay
                    required property string isubJson
                    required property int rDepth
                    required property int rParent
                    required property int rPos
                    required property bool rGroupBg
                    required property bool rGroupTop
                    required property bool rGroupBottom
                    required property int index

                    readonly property string _idRef: itype === "popout" ? iwidgetId : ipluginId
                    readonly property int _subCount: itype === "submenu" ? JSON.parse(isubJson || "[]").length : 0
                    readonly property bool _expanded: itype === "submenu" && !!root.editorExpanded[rPos]

                    // "Move to" destinations for this item (folders + top level), minus current.
                    readonly property var _moveDests: {
                        if (itype === "submenu") return []
                        const out = []
                        if (rParent >= 0) out.push({ label: "Top level", parent: -1 })
                        const fs = root._folders
                        for (let i = 0; i < fs.length; i++) {
                            if (fs[i].index === rParent) continue
                            out.push({ label: fs[i].label, parent: fs[i].index })
                        }
                        return out
                    }
                    readonly property bool _canMove: itype !== "submenu" && _moveDests.length > 0

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
                    height: card.height

                    // Shaded band behind an expanded folder + its items. Each member
                    // row draws its slice; non-top members stretch up by the list
                    // spacing to bridge the gap, so the band reads as one continuous
                    // rounded container. Painted before the card, so it sits behind.
                    Rectangle {
                        visible: itemDelegate.rGroupBg
                        color: Theme.withAlpha(Theme.secondaryContainer, 0.4)
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: itemDelegate.rGroupTop ? -Theme.spacingXS : -itemsListView.spacing
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: itemDelegate.rGroupBottom ? -Theme.spacingXS : 0
                        topLeftRadius: itemDelegate.rGroupTop ? Theme.cornerRadius : 0
                        topRightRadius: itemDelegate.rGroupTop ? Theme.cornerRadius : 0
                        bottomLeftRadius: itemDelegate.rGroupBottom ? Theme.cornerRadius : 0
                        bottomRightRadius: itemDelegate.rGroupBottom ? Theme.cornerRadius : 0
                    }

                    // Visible card, inset from the left for nested rows so the whole
                    // container sits indented under its folder. (ListView owns the
                    // delegate's x, so we inset an inner card, not the root.)
                    StyledRect {
                        id: card
                        anchors.left: parent.left
                        anchors.right: parent.right
                        // Uniform horizontal padding on every card (plus the nesting
                        // indent on the left) so rows align and the shaded group band
                        // shows as a frame on both sides.
                        anchors.leftMargin: Theme.spacingS + itemDelegate.rDepth * Theme.spacingL
                        anchors.rightMargin: Theme.spacingS
                        height: itemRow.implicitHeight + Theme.spacingS * 2
                        radius: Theme.cornerRadius
                        color: (root.editingParent === itemDelegate.rParent && root.editingPos === itemDelegate.rPos)
                            ? Theme.primaryContainer
                            : (itemDelegate.itype === "submenu" ? Theme.surfaceContainerHigh
                            : (editItemArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer))

                        Behavior on color { ColorAnimation { duration: Theme.shortDuration } }

                    // Reorder drop indicators: before this row, or after the last sibling.
                    Rectangle {
                        width: parent.width; height: 2; color: Theme.primary
                        anchors.top: parent.top; anchors.topMargin: -Theme.spacingS / 2
                        visible: itemsListView.draggedIndex >= 0 && itemsListView.dropAboveProj === index
                    }
                    Rectangle {
                        width: parent.width; height: 2; color: Theme.primary
                        anchors.bottom: parent.bottom; anchors.bottomMargin: -Theme.spacingS / 2
                        visible: itemsListView.draggedIndex >= 0 && itemsListView.dropAboveProj === -1
                                 && itemsListView.dropLastSibProj === index
                    }

                    opacity: itemsListView.draggedIndex === index ? 0.5 : 1.0

                    // Click the row body (not chevron/handle/move/remove) to edit it.
                    MouseArea {
                        id: editItemArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // Edit shares the same form, which now lives in the dialog.
                        onClicked: { root._editItem(index); addItemPopup.open() }
                    }

                    Row {
                        id: itemRow
                        anchors.left: parent.left
                        anchors.right: itemDelegate.itype === "submenu" ? addInsideBtn.left
                                     : (itemDelegate._canMove ? moveDropdown.left : removeItemBtn.left)
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingS

                        // Reorder handle
                        Rectangle {
                            width: 24; height: 32; radius: 4
                            color: reorderArea.pressed ? Theme.surfaceContainerHighest : "transparent"
                            anchors.verticalCenter: parent.verticalCenter

                            DankIcon { anchors.centerIn: parent; name: "reorder"; size: 18; color: Theme.surfaceVariantText }

                            MouseArea {
                                id: reorderArea
                                anchors.fill: parent
                                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                preventStealing: true
                                onPressed: (mouse) => { mouse.accepted = true; const p = mapToItem(itemsListView, mouse.x, mouse.y); itemsListView.updateDropIndex(index, p.y) }
                                onPositionChanged: (mouse) => { if (!pressed) return; mouse.accepted = true; const p = mapToItem(itemsListView, mouse.x, mouse.y); itemsListView.updateDropIndex(index, p.y) }
                                onReleased: (mouse) => { mouse.accepted = true; itemsListView.finishDrag() }
                                onCanceled: { itemsListView.draggedIndex = -1; itemsListView.draggedParent = -2; itemsListView.dropAboveProj = -1; itemsListView.dropLastSibProj = -1 }
                            }
                        }

                        // Expand/collapse chevron (folders only); reserved slot keeps icons aligned.
                        Item {
                            width: 18; height: 32
                            anchors.verticalCenter: parent.verticalCenter
                            visible: itemDelegate.itype === "submenu"
                            DankIcon {
                                anchors.centerIn: parent
                                name: itemDelegate._expanded ? "expand_more" : "chevron_right"
                                size: 18
                                color: Theme.surfaceText
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root._toggleEditorExpand(itemDelegate.rPos)
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
                            width: parent.width - 24 - (itemDelegate.itype === "submenu" ? 18 + parent.spacing : 0) - (Theme.iconSize - 4) - (parent.spacing * 2)

                            StyledText {
                                text: resolvedLabel
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: itemDelegate.itype === "submenu" ? Font.Medium : Font.Normal
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
                                    height: 18; width: typeBadge.implicitWidth + 10; radius: 9
                                    color: itype === "action" ? Theme.secondaryContainer : Theme.tertiaryContainer
                                    StyledText { id: typeBadge; anchors.centerIn: parent; text: itype; font.pixelSize: 10; color: Theme.surfaceText; font.weight: Font.Bold }
                                }

                                StyledRect {
                                    id: displayBadgeRect
                                    height: 18; width: displayBadge.implicitWidth + 10; radius: 9
                                    color: Theme.surfaceContainerHighest
                                    StyledText { id: displayBadge; anchors.centerIn: parent; text: idisplay; font.pixelSize: 10; color: Theme.surfaceText; font.weight: Font.Medium }
                                }

                                StyledText {
                                    width: subtitleRow.width - typeBadgeRect.width - displayBadgeRect.width - Theme.spacingXS * 2
                                    text: itype === "submenu"
                                        ? (_subCount + (_subCount === 1 ? " item" : " items"))
                                        : (itype === "action" ? icommand : (itype === "popout" ? iwidgetId : ipluginId))
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }

                    // Per-row "Move to" — non-folder items with at least one destination.
                    DankDropdown {
                        id: moveDropdown
                        visible: itemDelegate._canMove
                        anchors.right: removeItemBtn.left
                        anchors.rightMargin: Theme.spacingXS
                        anchors.verticalCenter: parent.verticalCenter
                        compactMode: true
                        dropdownWidth: 148
                        text: ""
                        emptyText: "Move to…"
                        options: itemDelegate._moveDests.map(d => d.label)
                        onValueChanged: (value) => {
                            const d = itemDelegate._moveDests.find(x => x.label === value)
                            if (d) root._moveItem(itemDelegate.rParent, itemDelegate.rPos, d.parent)
                        }
                    }

                    // Add-inside (folders only): next adds land in this folder.
                    DankActionButton {
                        id: addInsideBtn
                        visible: itemDelegate.itype === "submenu"
                        iconName: "add"
                        buttonSize: 32
                        anchors.right: removeItemBtn.left
                        anchors.rightMargin: Theme.spacingXS
                        anchors.verticalCenter: parent.verticalCenter
                        tooltipText: "Add item inside this folder"
                        onClicked: root._openAddDialog(itemDelegate.rPos)
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
                            onClicked: root._removeItemAt(itemDelegate.rParent, itemDelegate.rPos)
                        }
                    }
                    }

                    // Hover the gap above a row to reveal a "+" that inserts a new
                    // item *before* it, at this row's level/indent (Word-table style).
                    Item {
                        z: 10
                        anchors.left: card.left
                        anchors.right: card.right
                        anchors.top: parent.top
                        anchors.topMargin: -itemsListView.spacing
                        height: itemsListView.spacing + 6
                        visible: itemsListView.draggedIndex < 0

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            height: 2
                            radius: 1
                            color: Theme.primary
                            visible: insertArea.containsMouse
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: 20; height: 20; radius: 10
                            color: Theme.primary
                            visible: insertArea.containsMouse
                            DankIcon { anchors.centerIn: parent; name: "add"; size: 14; color: Theme.onPrimary }
                        }

                        MouseArea {
                            id: insertArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._openInsertDialog(itemDelegate.rParent, itemDelegate.rPos)
                        }
                    }
                }
            }

        }
        // ── Add / Edit item dialog ───────────────────────────────────────────
        // The shared form lives here (modal overlay, like DropdownIconPicker) so
        // adding/editing happens in a focused dialog instead of a form far below
        // the list. Opened by the folder "+", the "Add item…" button, and (row
        // click) editing.
        Popup {
            id: addItemPopup
            parent: Overlay.overlay
            modal: true
            dim: false
            padding: 0
            closePolicy: Popup.CloseOnEscape   // Esc hard-closes; outside-click is handled below
            x: 0
            y: 0
            width: Overlay.overlay?.width ?? 900
            height: Overlay.overlay?.height ?? 800
            onOpened: root._itemOpenSnapshot = root._itemFormSnapshot()

            background: Rectangle { color: "transparent" }

            contentItem: Item {
                // Scrim over the whole overlay: a click outside the card closes the
                // dialog if unchanged, or prompts (Save/Discard/Cancel) if dirty.
                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(0, 0, 0, 0.45)
                    MouseArea { anchors.fill: parent; onClicked: root._tryCloseItemDialog() }
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: Math.min(600, parent.width - 80)
                    height: Math.min(640, parent.height - 80)
                    color: Theme.surface
                    radius: Theme.cornerRadius

                    MouseArea { anchors.fill: parent }   // absorb clicks on the card so they don't hit the scrim

                    Flickable {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingL
                        contentHeight: dialogForm.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        Column {
                            id: dialogForm
                            width: parent.width
                            spacing: Theme.spacingM

            Row {
                width: parent.width
                spacing: Theme.spacingS

                StyledText {
                    text: root._isEditing ? "Edit Item" : "Add Item"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: root._isEditing ? Theme.primary : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }

                // "Adding into <folder>" chip — click ✕ to add to top level instead.
                Rectangle {
                    visible: !root._isEditing && root.addTargetParent >= 0
                    height: 22
                    width: addToRow.implicitWidth + Theme.spacingS * 2
                    radius: 11
                    color: Theme.primaryContainer
                    anchors.verticalCenter: parent.verticalCenter

                    Row {
                        id: addToRow
                        anchors.centerIn: parent
                        spacing: Theme.spacingXS
                        DankIcon { name: "folder"; size: 12; color: Theme.onPrimaryContainer; anchors.verticalCenter: parent.verticalCenter }
                        StyledText {
                            text: "into " + (root._folders.find(f => f.index === root.addTargetParent)?.label || "folder")
                            font.pixelSize: 10
                            color: Theme.onPrimaryContainer
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        DankIcon {
                            name: "close"; size: 12; color: Theme.onPrimaryContainer
                            anchors.verticalCenter: parent.verticalCenter
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.addTargetParent = -1 }
                        }
                    }
                }
            }

            // Quick Add — pre-fills the form with a common panel (add mode only);
            // the user reviews/tweaks, then clicks Add Item to actually save.
            Column {
                width: parent.width
                spacing: Theme.spacingXS
                visible: !root._isEditing

                StyledText {
                    text: "Quick add a common panel"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                Flow {
                    width: parent.width
                    spacing: Theme.spacingS

                    Repeater {
                        model: root.quickAddItems

                        delegate: Rectangle {
                            required property var modelData

                            // Highlight the chip currently pre-filled into the form.
                            readonly property bool selected: root.newItemType === "plugin"
                                && root.newItemPluginId === modelData.pluginId

                            height: 32
                            width: chipRow.implicitWidth + Theme.spacingM * 2
                            radius: height / 2
                            color: selected
                                ? Theme.withAlpha(Theme.primary, 0.15)
                                : (chipArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer)
                            border.color: selected ? Theme.primary : "transparent"
                            border.width: selected ? 1 : 0

                            Behavior on color { ColorAnimation { duration: Theme.shortDuration } }

                            Row {
                                id: chipRow
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS
                                DankIcon { name: modelData.icon; size: 14; color: selected ? Theme.primary : Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                                StyledText { text: modelData.label; font.pixelSize: Theme.fontSizeSmall; color: selected ? Theme.primary : Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }
                            }

                            MouseArea {
                                id: chipArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    // Pre-fill the Plugin form with a toggle default —
                                    // does NOT save until the user clicks Add Item.
                                    root.newItemType = "plugin"
                                    root.newItemPluginId = modelData.pluginId
                                    root.newItemIcon = modelData.icon
                                    root.newItemLabel = ""
                                    pluginIconField.currentIcon = modelData.icon
                                    pluginLabelField.text = ""
                                    pluginPicker.currentValue = root._displayNameFor(modelData.pluginId)
                                    root._detectPluginCommands(modelData.pluginId)
                                    root.newPluginActionKind = "toggle"
                                }
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.outlineVariant; opacity: 0.3 }
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

                // Sub-menus only nest one level, so a folder can only be added at
                // the top level (not when the add target is a folder).
                DankButton {
                    text: "Sub-menu"
                    iconName: "folder"
                    buttonHeight: 32
                    visible: root.addTargetParent < 0
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
                    text: root._isEditing ? "Update Item" : "Add Item"
                    iconName: root._isEditing ? "check" : "add"
                    onClicked: root._commitItemForm()
                }

                DankButton {
                    text: "Cancel"
                    backgroundColor: Theme.surfaceContainerHigh
                    textColor: Theme.surfaceText
                    onClicked: { root._resetItemForm(); addItemPopup.close() }
                }
            }
                        }
                    }
                }
            }
        }
    }
}
