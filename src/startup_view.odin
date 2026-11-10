package inspecteur

// The Startup section (startup.odin): what starts with the session. Its bar, a row's menu and the keys (commands.odin)
// act on the selected item: Enable (it starts with the session), Disable, Enable or disable (Space), Open file location
// (its file's folder in the file manager), Copy command.

import "core:fmt"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"

build_startup :: proc(app: ^App, em: f32) {
	s := &app.startup
	if s.rows.table.query != app.query { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
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
	ev := section_table_build(&s.rows, s.list != nil ? "Nothing starts with the session." : "")
	if ev.sorted { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
	if ev.activated && cmd_can(app, .Startup_Open) { startup_open(app) }
	if ev.menu { startup_menu_open(app, ev.menu_at) }
	startup_menu(app, em)
}

// Whether a command of the section can act on the selected item now.
startup_can :: proc(app: ^App, c: Cmd) -> bool {
	it, ok := selected_startup(app)
	if !ok || app.startup.pending { return false }
	#partial switch c {
	case .Startup_Enable:  return it.can_toggle && !it.enabled
	case .Startup_Disable: return it.can_toggle && it.enabled
	case .Startup_Toggle:  return it.can_toggle
	case .Startup_Open:    return it.path != ""
	case .Startup_Copy:    return it.command != ""
	}
	return false
}

@(private = "file")
startup_actions :: proc(app: ^App, em: f32) {
	cmd_button(app, "st_enable", lucide.CHECK, .Startup_Enable, em)
	cmd_button(app, "st_disable", lucide.X, .Startup_Disable, em)
	vrule(em)
	cmd_button(app, "st_open", lucide.FOLDER_OPEN, .Startup_Open, em)
	cmd_button(app, "st_copy", lucide.COPY, .Startup_Copy, em)
}

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
	if ui.ctx_menu(s.menu) {
		if _, ok := selected_startup(app); !ok { ui.ctx_menu_close(); return }
		cmd_item(app, .Startup_Enable)
		cmd_item(app, .Startup_Disable)
		ui.menu_separator()
		cmd_item(app, .Startup_Open)
		cmd_item(app, .Startup_Copy)
	}
}

startup_toggle :: proc(app: ^App, on: bool) {
	it, ok := selected_startup(app)
	if !ok { return }
	app.startup.pending = true
	say(app, "%s %s…", on ? "Enabling" : "Disabling", it.name)
	startup_ask(app, true, it, on)
}

startup_open :: proc(app: ^App) {
	it, ok := selected_startup(app)
	if !ok || it.path == "" { return }
	if platform.reveal_in_folder(it.path) { say(app, "Opened the folder of %s", it.path) } else { say(app, "No file manager opens %s", it.path) }
}

startup_copy :: proc(app: ^App) {
	it, ok := selected_startup(app)
	if !ok || it.command == "" { return }
	platform.set_clipboard(app.main.win, it.command)
	say(app, "Copied the command of %s", it.name)
}
