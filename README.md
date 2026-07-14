# Dropdown Menu

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) (DMS) bar plugin that adds a configurable button to the bar which opens a **dropdown menu** of actions, plugin toggles, popouts, and DMS IPC commands.

> Status: **beta** (v0.7.0)

## Screenshots

![A Dropdown Menu open on the bar](assets/dropdown-menu.png)

## Features

- **One bar button → a menu of anything.** Build a dropdown of mixed item types:
  - **Custom Action** — run any shell command.
  - **Plugin** — toggle/open a plugin, **Open its popout** (works even if the widget isn't on a bar — see below), or run one of its **detected IPC actions**.
  - **IPC Command** — pick any live `dms ipc` target + function (discovered **on demand** from your running shell).
- **On-demand popouts & actions** — "popout" items open the target widget's *real* popout, and a plugin's **IPC actions** fire, **without that widget taking up bar space**. The dropdown instantiates the plugin off-bar so its popout and `IpcHandler` work, anchored under the dropdown button. Put a widget behind the menu instead of on the bar.
- **Smart action defaults** — a widget plugin defaults to opening its popout; daemons and built-in panels default to toggle/open (the action that actually makes sense for each).
- **Per-plugin action detection** — opt into scanning a selected plugin for `IpcHandler` actions and offer them directly (e.g. a Pomodoro plugin exposes *Start Work*, *Reset*, …).
- **Quick Add** chips for common DMS panels (Control Center, Notifications, Clipboard, …) — one click to add, with live "already added" highlighting.
- **Smart plugin list** — only shows plugins you can actually drive from the menu, and flags ones that are **not enabled** or **not on a bar**.
- **Full Material icon picker** (searchable, all ~4000 symbols) for the button and each item.
- **Display modes** — show icon, text, or both, per bar pill and per item.
- **Multiple dropdowns** via variants — each is a separate bar widget.
- **Sub-menus** — group items into nested, collapsible groups. A sub-menu row expands *in place* (accordion) with its children indented below, and the popout grows to fit. Edit a group by **drilling into it** (breadcrumb + back) and reuse the same add/reorder/remove controls. One level of nesting; off-bar popout/IPC hosting works for items inside groups too.
- **Drag-to-reorder** items by a handle, click-to-edit, and remove; collapsible editor.

## Requirements

- DankMaterialShell (quickshell-based) with the plugin system.
- `dms` CLI on `PATH` (used for IPC actions).

## Install

### From the DMS plugin registry (once published)

```sh
dms plugins install dropdownMenu
```

### Manual

Clone into your DMS plugins directory:

```sh
git clone https://github.com/rdannenbring/dropdown-menu.git \
  ~/.config/DankMaterialShell/plugins/dropdownMenu
```

Then enable it in **DMS Settings → Plugins**, configure a dropdown, and add it to your bar via **Bar Settings → Add Widget**.

## Usage

1. Enable the plugin in **Settings → Plugins** and open its settings.
2. Create a dropdown, then click it to edit.
3. Add items (Custom Action / Plugin / IPC Command / Sub-menu); use Quick Add for common panels. Click a Sub-menu row to drill in and add items inside it.
4. Set the bar pill's icon, label, and display mode.
5. **Bar Settings → Add Widget** to place the dropdown on your bar.

Clicking the dropdown on the bar opens/closes its menu.

## Permissions

`settings_read`, `settings_write`, `process` (to run shell/IPC commands).

## How it works

Each dropdown is a DMS plugin **variant**, so multiple dropdowns are independent bar widgets. The bar pill is a `PluginComponent`; the menu is its popout.

**Files**

- `DropdownWidget.qml` — the bar pill + popout; dispatches item clicks.
- `DropdownItem.qml` — a single menu row.
- `DropdownSettings.qml` — the editor (variants, items, IPC discovery, validation).
- `DropdownIconPicker.qml` — searchable Material-symbol picker.

**Item model** (stored in variant data)

- `action` — `{ command }`, run via `Process` (`sh -c`).
- `plugin` — `{ pluginId }`, toggled via `PluginService.togglePlugin` or a built-in `PopoutService` toggle.
- `popout` — `{ widgetId }`, opened **on demand**: the dropdown instantiates the target plugin's widget off-bar (hidden, zero-size, non-interactive, inside its own bar pill, with full bar context injected) and calls the widget's own `triggerPopout()`, so the popout opens anchored under the dropdown button without the widget being placed on a bar. If a copy *is* on a bar, it falls back to `BarWidgetService.triggerWidgetPopout`. The off-bar instance runs in the background (timers/fetches) so its popout has data ready.
- IPC actions are stored as `action` items whose command is `dms ipc <target> <fn> [args]` — reusing the action execution path.
- `submenu` — `{ label, icon, items: [...] }`, a nested group of same-shape items rendered as an inline accordion (one level). The off-bar popout/IPC hosting recurses into `items`, so nested popout/IPC entries work too.

**Discovery** (opt-in)

- Listing IPC targets/functions runs `dms ipc --help` against the running shell — triggered **only** when you click **Load IPC targets** / **Detect IPC actions**, never automatically. It enumerates every live `IpcHandler`, which can crash the shell if a plugin registers an un-wireable handler (an upstream quickshell `wireDef` bug), so the common flows — Custom Action, toggle/open, popout, Sub-menu — never invoke it. Already know the command? Add it as a **Custom Action** (`dms ipc <target> <fn>`) to skip discovery.
- Per-plugin actions: the selected plugin's QML is grepped for `IpcHandler { target: "…" }` and intersected with the live target list, so only working actions are offered.

## License

[MIT](LICENSE)
