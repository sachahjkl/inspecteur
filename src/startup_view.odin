package inspecteur

// The Startup section (startup.odin): what starts with the session. Its bar, a row's menu and the keys (commands.odin)
// act on the items selected: Enable (it starts with the session), Disable, Enable or disable (Space: the cursor's item
// says which, the others selected go the same way), Copy command; and on the cursor's: Open file location (its file's
// folder in the file manager).

import "core:fmt"
import "core:strings"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"
import i18n "gt:i18n"

build_startup :: proc(app: ^App, em: f32) {
	s := &app.startup
	if s.rows.table.query != app.query { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
	note := i18n.tr("Reading…")
	if s.pending {
		note = i18n.tr("Changing…")
	} else if s.list != nil {
		on := 0
		for it in s.list.items { if it.enabled { on += 1 } }
		note = fmt.tprintf(i18n.tr(len(s.list.items), "%d item, %d on", "%d items, %d on"), len(s.list.items), on)
	}
	section_bar(app, i18n.tr("Startup"), note, em, startup_actions)
	// (what could not be read, on lines of its own under the bar: in the bar's one line, a long sentence was cut)
	if !s.pending && s.list != nil && s.list.problem != "" {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Start, {.Draw_Side_Bottom}, "###startup_problem") {
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") {
				ui.next({width = ui.fill()})
				ui.paragraph(fmt.tprintf("%s###startup_problem_text", s.list.problem))
			}
			ui.spacer(ui.px(em * 0.8))
		}
	}
	ev := section_table_build(&s.rows, s.list != nil ? i18n.tr("Nothing starts with the session.") : "")
	if ev.sorted { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
	if ev.sorted || ev.resized || ev.moved { section_layout_save(&s.rows, &app.prefs, "startup") }
	section_header_menu(&s.rows, ev, "startup", em)
	if ev.activated && cmd_can(app, .Startup_Open) { startup_open(app) }
	if ev.menu { startup_menu_open(app, ev.menu_at) }
	startup_menu(app, em)
}

// Whether a command of the section can act now: Enable and Disable on one of the items selected at least, the others on
// the cursor's.
startup_can :: proc(app: ^App, c: Cmd) -> bool {
	it, ok := selected_startup(app)
	if !ok || app.startup.pending { return false }
	#partial switch c {
	case .Startup_Enable:  return len(startup_targets(app, true)) > 0
	case .Startup_Disable: return len(startup_targets(app, false)) > 0
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

STARTUP_MENU :: "inspecteur_startup_menu"

startup_menu_open :: proc(app: ^App, pos: ui.Vec2, from_keyboard := false) {
	if _, ok := selected_startup(app); !ok { return }
	ui.menu_open(STARTUP_MENU, pos, from_keyboard = from_keyboard)
}

@(private = "file")
startup_menu :: proc(app: ^App, em: f32) {
	if ui.menu(STARTUP_MENU) {
		if _, ok := selected_startup(app); !ok { ui.menu_close(); return }
		cmd_item(app, .Startup_Enable)
		cmd_item(app, .Startup_Disable)
		ui.menu_separator()
		cmd_item(app, .Startup_Open)
		cmd_item(app, .Startup_Copy)
	}
}

// The items selected that can be turned `on` (or off) and are not already, in the order shown.
startup_targets :: proc(app: ^App, on: bool) -> []Startup_Item {
	s := &app.startup
	out := make([dynamic]Startup_Item, context.temp_allocator)
	if s.list == nil { return out[:] }
	for r in selected_rows(&s.rows.table) {
		if r >= len(s.list.items) { continue }
		it := s.list.items[r]
		if it.can_toggle && it.enabled != on { append(&out, it) }
	}
	return out[:]
}

// The items selected turned on (or off), those already so left as they are.
startup_toggle :: proc(app: ^App, on: bool) {
	items := startup_targets(app, on)
	if len(items) == 0 { return }
	app.startup.pending = true
	what := len(items) == 1 ? items[0].name : fmt.tprintf(i18n.tr(len(items), "%d item", "%d items"), len(items))
	say(app, on ? i18n.tr("Enabling %s…") : i18n.tr("Disabling %s…"), what)
	startup_ask(app, true, items, on)
}

startup_open :: proc(app: ^App) {
	it, ok := selected_startup(app)
	if !ok || it.path == "" { return }
	ui.open(it.path, .Reveal)
	say(app, i18n.tr("Opened the folder of %s"), it.path)
}

// The commands of the items selected, a line each.
startup_copy :: proc(app: ^App) {
	s := &app.startup
	if s.list == nil { return }
	lines := make([dynamic]string, context.temp_allocator)
	name := ""
	for r in selected_rows(&s.rows.table) {
		if r >= len(s.list.items) || s.list.items[r].command == "" { continue }
		append(&lines, s.list.items[r].command)
		name = s.list.items[r].name
	}
	if len(lines) == 0 { return }
	platform.set_clipboard(app.main.win, strings.join(lines[:], "\n", context.temp_allocator))
	if len(lines) == 1 {
		announce(app, fmt.tprintf(i18n.tr("Copied the command of %s"), name))
	} else {
		announce(app, fmt.tprintf(i18n.tr(len(lines), "Copied the command of %d item", "Copied the commands of %d items"), len(lines)))
	}
}
