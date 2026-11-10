package inspecteur

// The Startup section (startup.odin): what starts with the session. Its bar and a row's menu act on the selected item:
//
//   Enable              Ctrl+E        it starts with the session
//   Disable             Ctrl+D        it does not
//   Enable or disable   Space
//   Open file location  Enter         its file's folder in the file manager
//   Copy command        Ctrl+C

import "core:fmt"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"

build_startup :: proc(app: ^App, em: f32) {
	s := &app.startup
	if s.grid.query != app.query { grid_apply(&s.grid, &s.data, app.query) }
	note := "Reading…"
	if s.pending {
		note = "Changing…"
	} else if s.list != nil {
		on := 0
		for it in s.list.items { if it.enabled { on += 1 } }
		note = fmt.tprintf("%s, %d on", count_text(len(s.list.items), "item", "items"), on)
		if s.list.problem != "" { note = fmt.tprintf("%s. %s", note, s.list.problem) }
	}
	section_bar(app, "Startup", note, em, startup_actions)
	ev := grid_build(app, &s.grid, &s.data, s.list != nil ? "Nothing starts with the session." : "", em)
	if ev.sorted { grid_apply(&s.grid, &s.data, app.query) }
	if ev.activated { startup_open(app) }
	if ev.menu { startup_menu_open(app, ui.mouse_pos()) }
	startup_menu(app, em)
}

@(private = "file")
Startup_Can :: struct { enable, disable, open, copy: bool }

@(private = "file")
startup_can :: proc(app: ^App) -> (can: Startup_Can) {
	it, ok := selected_startup(app)
	if !ok || app.startup.pending { return }
	can.enable = it.can_toggle && !it.enabled
	can.disable = it.can_toggle && it.enabled
	can.open = it.path != ""
	can.copy = it.command != ""
	return
}

@(private = "file")
startup_actions :: proc(app: ^App, em: f32) {
	can := startup_can(app)
	if tool_button(app, "st_enable", lucide.CHECK, "Enable: it starts with the session (Ctrl+E)", can.enable, em) { startup_toggle(app, true) }
	if tool_button(app, "st_disable", lucide.X, "Disable: it does not start with the session (Ctrl+D)", can.disable, em) { startup_toggle(app, false) }
	vrule(em)
	if tool_button(app, "st_open", lucide.FOLDER_OPEN, "Open file location (Enter)", can.open, em) { startup_open(app) }
	if tool_button(app, "st_copy", lucide.COPY, "Copy command (Ctrl+C)", can.copy, em) { startup_copy(app) }
}

// The keys of the section (view_keys calls it when no menu or dialog is open). `field_keeps`: the filter keeps its keys.
startup_keys :: proc(app: ^App, field_keeps: bool) {
	s := &app.startup
	grid_keys(&s.grid)
	can := startup_can(app)
	if ui.key_press(.E, {.Ctrl}) && can.enable { startup_toggle(app, true) }
	if ui.key_press(.D, {.Ctrl}) && can.disable { startup_toggle(app, false) }
	if !field_keeps {
		if ui.key_press(.C, {.Ctrl}) && can.copy { startup_copy(app) }
	}
	// (Space is the filter's while it has the keyboard: a space in a name)
	if ui.focus_key() != app.search_key && ui.key_press(.Space) && (can.enable || can.disable) { startup_toggle(app, can.enable) }
	if ui.key_press(.Return) && can.open { startup_open(app) }
	if ui.key_press(.Menu) || ui.key_press(.F10, {.Shift}) { startup_menu_open(app, {s.grid.sel_rect.min.x + 40, s.grid.sel_rect.max.y}, true) }
}

@(private = "file")
startup_menu_open :: proc(app: ^App, pos: ui.Vec2, from_keyboard := false) {
	s := &app.startup
	if _, ok := selected_startup(app); !ok { return }
	if s.menu == 0 { s.menu = ui.key_from_string(0, "inspecteur_startup_menu") }
	ui.ctx_menu_open(s.menu, pos, from_keyboard = from_keyboard)
}

@(private = "file")
startup_menu :: proc(app: ^App, em: f32) {
	s := &app.startup
	if s.menu == 0 { return }
	if ui.ctx_menu(s.menu, em * MENU_WIDTH_EM) {
		if _, ok := selected_startup(app); !ok { ui.ctx_menu_close(); return }
		can := startup_can(app)
		if ui.menu_item("Enable", "Ctrl+E", enabled = can.enable).clicked { startup_toggle(app, true) }
		if ui.menu_item("Disable", "Ctrl+D", enabled = can.disable).clicked { startup_toggle(app, false) }
		ui.menu_separator()
		if ui.menu_item("Open file location", "Enter", enabled = can.open).clicked { startup_open(app) }
		if ui.menu_item("Copy command", "Ctrl+C", enabled = can.copy).clicked { startup_copy(app) }
	}
}

@(private = "file")
startup_toggle :: proc(app: ^App, on: bool) {
	it, ok := selected_startup(app)
	if !ok { return }
	app.startup.pending = true
	say(app, "%s %s…", on ? "Enabling" : "Disabling", it.name)
	startup_ask(app, true, it, on)
}

@(private = "file")
startup_open :: proc(app: ^App) {
	it, ok := selected_startup(app)
	if !ok || it.path == "" { return }
	if platform.reveal_in_folder(it.path) { say(app, "Opened the folder of %s", it.path) } else { say(app, "No file manager opens %s", it.path) }
}

@(private = "file")
startup_copy :: proc(app: ^App) {
	it, ok := selected_startup(app)
	if !ok || it.command == "" { return }
	platform.set_clipboard(app.main.win, it.command)
	say(app, "Copied the command of %s", it.name)
}
