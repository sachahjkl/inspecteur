package inspecteur

// Windows Startup section view: displays Registry Run keys (HKCU/HKLM, 64-bit & 32-bit),
// User and Common Startup folders, and Task Scheduler logon entries, with StartupApproved toggling.

import "core:fmt"
import "core:strings"
import i18n "gt:i18n"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"

STARTUP_MENU :: "inspecteur_win_startup_menu"

build_startup :: proc(app: ^App, em: f32) {
	s := &app.startup
	if s.rows.table.query != app.query { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
	note := i18n.tr("Reading…")
	if s.pending {
		note = i18n.tr("Changing…")
	} else if s.list != nil {
		note = fmt.tprintf(i18n.tr(len(s.list.items), "%d item, %d on", "%d items, %d on"), len(s.list.items), s.list.on_count)
	}
	section_bar(app, i18n.tr("Startup"), note, em, win_startup_actions)

	if !s.pending && s.list != nil && s.list.problem != "" {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Start, {.Draw_Side_Bottom}, "###startup_problem") {
			ui.space(ui.SPACE_3)
			if ui.tags("weak") {
				ui.next({width = ui.fill()})
				ui.paragraph(fmt.tprintf("%s###t", s.list.problem))
			}
			ui.space(ui.SPACE_3)
		}
	}
	ev := section_table_build(&s.rows, s.list != nil ? i18n.tr("Nothing starts with Windows.") : "")
	if ev.sorted { ui.table_apply(&s.rows.table, &s.rows.data, app.query) }
	if ev.sorted || ev.resized || ev.moved { section_layout_save(&s.rows, &app.prefs, "startup") }
	section_header_menu(&s.rows, ev, "startup", em)
	if ev.activated && cmd_can(app, .Startup_Open) { startup_open(app) }
	if ev.menu { startup_menu_open(app, ev.menu_at) }
	win_startup_menu(app)
}

startup_can :: proc(app: ^App, c: Cmd) -> bool {
	it, ok := selected_startup(app)
	if !ok || app.startup.pending { return false }
	#partial switch c {
	case .Startup_Enable:        return len(win_startup_targets(app, true)) > 0
	case .Startup_Disable:       return len(win_startup_targets(app, false)) > 0
	case .Startup_Toggle:        return it.can_toggle
	case .Startup_Open:          return it.target_path != ""
	case .Startup_Copy:          return it.command != ""
	case .Startup_Copy_Location: return it.location != ""
	}
	return false
}

@(private = "file")
win_startup_actions :: proc(app: ^App, em: f32) {
	cmd_button(app, "st_enable", lucide.CHECK, .Startup_Enable, em)
	cmd_button(app, "st_disable", lucide.X, .Startup_Disable, em)
	vrule(em)
	cmd_button(app, "st_open", lucide.FOLDER_OPEN, .Startup_Open, em)
	cmd_button(app, "st_copy", lucide.COPY, .Startup_Copy, em)
	cmd_button(app, "st_copy_loc", lucide.MAP_PIN, .Startup_Copy_Location, em)
}

startup_menu_open :: proc(app: ^App, pos: ui.Vec2, from_keyboard := false) {
	if _, ok := selected_startup(app); !ok { return }
	ui.menu_open(STARTUP_MENU, pos, from_keyboard = from_keyboard)
}

@(private = "file")
win_startup_menu :: proc(app: ^App) {
	if ui.menu(STARTUP_MENU) {
		if _, ok := selected_startup(app); !ok { ui.menu_close(); return }
		cmd_item(app, .Startup_Enable)
		cmd_item(app, .Startup_Disable)
		ui.menu_separator()
		cmd_item(app, .Startup_Open)
		cmd_item(app, .Startup_Copy)
		cmd_item(app, .Startup_Copy_Location)
	}
}

@(private = "file")
win_startup_targets :: proc(app: ^App, on: bool) -> []Win_Startup_Item {
	s := &app.startup
	out := make([dynamic]Win_Startup_Item, context.temp_allocator)
	if s.list == nil { return out[:] }
	for r in selected_rows(&s.rows.table) {
		if r >= len(s.list.items) { continue }
		it := s.list.items[r]
		if it.can_toggle && it.enabled != on { append(&out, it) }
	}
	return out[:]
}

startup_toggle :: proc(app: ^App, on: bool) {
	items := win_startup_targets(app, on)
	if len(items) == 0 { return }
	app.startup.pending = true
	what := len(items) == 1 ? items[0].name : fmt.tprintf(i18n.tr(len(items), "%d item", "%d items"), len(items))
	say(app, on ? i18n.tr("Enabling %s…") : i18n.tr("Disabling %s…"), what)
	startup_ask(app, true, items, on)
}

startup_open :: proc(app: ^App) {
	it, ok := selected_startup(app)
	if !ok || it.target_path == "" { return }
	ui.open(it.target_path, .Reveal)
	say(app, i18n.tr("Opened the folder of %s"), it.target_path)
}

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

startup_copy_location :: proc(app: ^App) {
	it, ok := selected_startup(app)
	if !ok || it.location == "" { return }
	platform.set_clipboard(app.main.win, it.location)
	announce(app, i18n.tr("Copied location"), it.location)
}

mission_startup :: proc(app: ^App, em: f32) {
	s := &app.startup
	if s.list == nil { mission_note(i18n.tr("Reading…"), em); return }
	on := s.list.on_count
	mission_note(fmt.tprintf(i18n.tr(len(s.list.items), "%d item, %d on", "%d items, %d on"), len(s.list.items), on), em)
	k := 0
	for it in s.list.items {
		if !it.enabled { continue }
		if mission_line(app, fmt.tprintf("mc_start_%d", k), it.name, i18n.tr(WIN_STARTUP_SOURCE_LABELS[it.source]), it.status, -1, "", em, {kind = .Startup, name = it.name}) {
			tab_show(app, .Startup)
		}
		k += 1
		if k >= MISSION_TOP { break }
	}
}
