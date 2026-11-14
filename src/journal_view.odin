package inspecteur

// The details' journal (the Services section's pane, services_view.odin): the selected service's journal entries, each
// with its time, its level in its colour, its program and process, and its message. Over them a bar: the level kept
// (all, warnings, errors, each with its count: Alt+L), this boot or every boot (Alt+B), following (Alt+F: read again
// every JOURNAL_FOLLOW_MS, new entries come in at the end while the view is there), a search of its own (Ctrl+J) and
// Copy (Alt+C: the entries shown). Under them, the selected entry whole: its date, its level, its program, its message
// wrapped (Alt+Shift+C copies it). A journal on its own (journal_window.odin) is built by the same procedures.

import "core:fmt"
import "core:strings"
import "core:time"
import "core:time/timezone"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"
import i18n "gt:i18n"

// Syslog's levels, by priority: the word the pane shows and the colour's tag ("" the text's own).
@(rodata)
JOURNAL_LEVEL_WORDS := [8]string{"emerg", "alert", "crit", "error", "warning", "notice", "info", "debug"}
@(rodata)
JOURNAL_LEVEL_TAGS := [8]string{"bad", "bad", "bad", "bad", "warn", "", "", "weak"}

// The widths of the entries' columns, in ems: the time (with the date: every boot), the level, the program.
@(private = "file") TIME_EM :: 5.4
@(private = "file") DATE_TIME_EM :: 9.4
@(private = "file") LEVEL_EM :: 4.8
@(private = "file") IDENT_EM :: 11
// The selected entry's strip: its line of facts and three lines of its message.
@(private = "file") ENTRY_EM :: 6

// The journal of the service `name` of `manager` in `v` (`wanted` false: no service is chosen yet). `in_window`: the
// journal is on its own already (no button to put it on its own).
journal_build :: proc(app: ^App, v: ^Journal_View, name: string, manager: Manager, wanted: bool, em: f32, in_window := false) {
	d := v.details
	if !wanted || d == nil || d.name != name || d.manager != manager {
		journal_note(!wanted ? i18n.tr("Select a service: its journal shows here.") : i18n.tr("Reading…"), em)
		return
	}
	shown := journal_shown(app, v)
	journal_bar(app, v, len(shown), em, in_window)
	switch {
	case len(d.journal) == 0: journal_note(d.journal_problem, em); return
	case len(shown) == 0:     journal_note(i18n.tr("No entry is shown: another level, or another search, shows some."), em); return
	}
	ids := v.shown_ids[:]   // (made with them: journal_shown)
	// (the newest entry in view: at another service, and as new entries come while the view was at the end)
	newest := ids[len(ids) - 1]
	if v.shown_for != name_id(name) {
		v.shown_for = name_id(name)
		v.vl.sel = -1
		ui.vlist_scroll_to(&v.vl, max(f32))
	} else if newest != v.last && journal_at_end(&v.vl) {
		ui.vlist_scroll_to(&v.vl, max(f32))
	}
	v.last = newest
	journal_list(app, v, shown, ids, em)
	if e, has := journal_selected(app, v); has { journal_entry_whole(app, e, em) }
}

// The entries' list. (A procedure of its own: the list is the parent until the end of the scope it is opened in)
@(private = "file")
journal_list :: proc(app: ^App, v: ^Journal_View, shown: []int, ids: []u64, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill()})
	rows, ok := ui.vlist("###svc_journal", &v.vl, ids)
	if !ok { return }
	for i in rows.first ..< rows.last { journal_row(app, v, v.details.journal[shown[i]], i, em) }
}

@(private = "file")
journal_note :: proc(text: string, em: f32) {
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(em * 2), text_pad = em * 0.8})
		ui.label(fmt.tprintf("%s###svc_journal_note", ui.text_shown(text)))
	}
}

// The indices of the entries the level and the search keep, the oldest first (the view's: valid until the reading, the
// level or the search changes). The counts of the levels are made with them (v.errors, v.warnings).
journal_shown :: proc(app: ^App, v: ^Journal_View) -> []int {
	d := v.details
	if d == nil { return nil }
	q := strings.to_lower(strings.trim_space(ui.line_edit_string(&v.search)), context.temp_allocator)
	if v.shown_of == v.serial && v.shown_level == app.settings.journal_level && v.shown_query == q { return v.shown[:] }
	v.shown_of, v.shown_level = v.serial, app.settings.journal_level
	delete(v.shown_query)
	v.shown_query = strings.clone(q)
	clear(&v.shown)
	clear(&v.shown_ids)
	v.errors, v.warnings = 0, 0
	for e, i in d.journal {
		if e.priority <= 3 { v.errors += 1 } else if e.priority == 4 { v.warnings += 1 }
		if !journal_level_keeps(app.settings.journal_level, e.priority) { continue }
		if q != "" && !strings.contains(strings.to_lower(e.message, context.temp_allocator), q) && !strings.contains(strings.to_lower(e.ident, context.temp_allocator), q) { continue }
		append(&v.shown, i)
		append(&v.shown_ids, journal_entry_id(e))
	}
	return v.shown[:]
}

// An entry's identity in the list: the same entry read again keeps its row (and the selection).
journal_entry_id :: proc(e: Journal_Entry) -> u64 { return name_id(e.message) ~ u64(e.usec) ~ (u64(u32(e.pid)) << 40) }

// Whether the view shows the list's end (or the list has no box yet).
@(private = "file")
journal_at_end :: proc(vl: ^ui.Virtual_List) -> bool {
	b := ui.box_from_key(vl.key)
	if b == nil { return true }
	return b.view_off.y >= ui.view_limit(b) - 2
}

// The bar over the entries: the level, the boot, following, the search, Copy, how many are shown.
@(private = "file")
journal_bar :: proc(app: ^App, v: ^Journal_View, shown: int, em: f32, in_window: bool) {
	d := v.details
	errors, warnings := v.errors, v.warnings   // (journal_shown counted them)
	// (two groups that wrap: in a narrow pane, or with a language's longer words, the search and its tools move under the
	// level and the boot instead of being cut)
	bar_h := ui.dense(em * 1.9)
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.flow({0, 0}, "###svc_journal_bar", .Center) {
		ui.next({width = ui.children_sum(), height = ui.px(ui.dense(em * 2.3))})
		if ui.row(.Center, {}, "###svc_journal_choices") {
			ui.spacer(ui.px(em * 0.8))
			// (in the order of Journal_Level)
			labels := [3]string{fmt.tprintf(i18n.tr("All %d"), len(d.journal)), fmt.tprintf(i18n.tr("Warnings %d"), warnings + errors), fmt.tprintf(i18n.tr("Errors %d"), errors)}
			key := ui.command_shortcut(COMMANDS[.Journal_Level])
			tips := [3]string{fmt.tprintf(i18n.tr("Every entry (%s)"), key), fmt.tprintf(i18n.tr("Warnings and worse (%s)"), key), fmt.tprintf(i18n.tr("Errors and worse (%s)"), key)}
			sel := int(app.settings.journal_level)
			ui.next({height = ui.px(bar_h)})   // (as wide as its labels: ui.segmented's own width)
			if ui.segmented("svc_journal_level", labels[:], &sel, tips[:]) { journal_level_set(app, Journal_Level(sel)) }
			ui.spacer(ui.px(em * 0.6))
			boot := app.settings.journal_boot ? 0 : 1
			bkey := ui.command_shortcut(COMMANDS[.Journal_Boot])
			btips := [2]string{fmt.tprintf(i18n.tr("The entries of this boot (%s)"), bkey), fmt.tprintf(i18n.tr("The last entries, from any boot (%s)"), bkey)}
			boot_labels := [2]string{i18n.tr("This boot"), i18n.tr("Every boot")}
			ui.next({height = ui.px(bar_h)})
			if ui.segmented("svc_journal_boot", boot_labels[:], &boot, btips[:]) { journal_boot_set(app, boot == 0) }
			ui.spacer(ui.px(em * 0.6))
			follow := app.settings.journal_follow
			ui.next({width = ui.px(em * 2.2), height = ui.px(bar_h)})
			tip := follow ? fmt.tprintf(i18n.tr("Following: new entries come in at the end (%s stops)"), ui.command_shortcut(COMMANDS[.Journal_Follow])) : cmd_tip(.Journal_Follow)
			if ui.button("svc_journal_follow", icon = follow ? lucide.ARROW_DOWN : lucide.PAUSE, o = {tip = tip, intent = follow ? .Primary : .Neutral, face = follow ? .Raised : .Ghost}).clicked { journal_run_on(app, v, .Journal_Follow) }
		}
		ui.next({width = ui.children_sum(), height = ui.px(ui.dense(em * 2.3))})
		if ui.row(.Center, {}, "###svc_journal_tools") {
			ui.spacer(ui.px(em * 0.6))
			// (the field as wide as its placeholder, at least JOURNAL_SEARCH_EM: the words are never cut)
			placeholder := fmt.tprintf(i18n.tr("Search the journal (%s)"), ui.command_shortcut(COMMANDS[.Journal_Search]))
			ui.next({width = ui.px(max(em * JOURNAL_SEARCH_EM, ui.text_width(ui.top_style().font, em, placeholder) + em * 2)), height = ui.px(bar_h)})
			res := ui.line_edit("###svc_journal_search", &v.search, {placeholder = placeholder})
			v.search_key = res.box.key
			ui.spacer(ui.px(em * 0.4))
			if ui.tags("weak") {
				n := shown == len(d.journal) ? fmt.tprintf(i18n.tr(shown, "%d entry", "%d entries"), shown) : fmt.tprintf(i18n.tr("%d of %d"), shown, len(d.journal))
				ui.next({width = ui.text_size(em * 0.4), height = ui.px(bar_h), text_pad = 0, font_size = em * 0.9})
				ui.label(fmt.tprintf("%s###svc_journal_count", n))
			}
			if tool_button("svc_journal_copy", lucide.COPY, cmd_tip(.Journal_Copy), len(d.journal) > 0, em) { journal_run_on(app, v, .Journal_Copy) }
			if !in_window && tool_button("svc_journal_window", lucide.EXTERNAL_LINK, cmd_tip(.Journal_Window), true, em) { journal_window_open(app, d.manager, d.name) }
			ui.spacer(ui.px(em * 0.4))
		}
	}
}

// The journal's search field, at least, in ems.
JOURNAL_SEARCH_EM :: 16

// One entry: its time, its level in its colour, its program and process, its message (in the level's colour when it is
// a warning or worse).
@(private = "file")
journal_row :: proc(app: ^App, v: ^Journal_View, e: Journal_Entry, i: int, em: f32) {
	d := v.details
	ui.next({height = ui.px(ui.dense(em * 1.6))})
	row := ui.list_row(&v.vl, i, "")
	tip := ""
	if ui.parent(row.box) {
		fs := em * 0.92
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			ui.next({width = ui.px(em * (d.boot ? TIME_EM : DATE_TIME_EM)), height = ui.pct(1), text_pad = 0, font_size = fs})
			ui.label(fmt.tprintf("%s###jt", journal_time_text(app, e.usec, !d.boot)))
		}
		tag := JOURNAL_LEVEL_TAGS[e.priority]
		if tag != "" { ui.push_tags(tag) }
		ui.next({width = ui.px(em * LEVEL_EM), height = ui.pct(1), text_pad = 0, font_size = fs})
		ui.label(fmt.tprintf("%s###jl", JOURNAL_LEVEL_WORDS[e.priority]))
		if tag != "" { ui.pop_tags() }
		who := e.pid > 0 ? fmt.tprintf("%s[%d]", e.ident, e.pid) : e.ident
		if ui.tags("weak") {
			ui.next({width = ui.px(em * IDENT_EM), height = ui.pct(1), text_pad = 0, font_size = fs})
			b := ui.build_box({.Draw_Text, .Clip}, fmt.tprintf("%s###jw", ui.text_shown(who)))
			if text_cut(b, who) { tip = who }
		}
		if tag != "" && tag != "weak" { ui.push_tags(tag) }
		line := journal_one_line(e.message)
		ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = fs})
		b := ui.build_box({.Draw_Text, .Clip}, fmt.tprintf("%s###jm", ui.text_shown(line)))
		if tag != "" && tag != "weak" { ui.pop_tags() }
		if text_cut(b, line) || line != e.message { tip = e.message }
	}
	ui.table_cell_tip(row, tip)
}

// A message on one line: its first line, with "…" when there are more.
@(private = "file")
journal_one_line :: proc(m: string) -> string {
	if i := strings.index_byte(m, '\n'); i >= 0 { return fmt.tprintf("%s …", m[:i]) }
	return m
}

// The selected entry, when one is shown.
journal_selected :: proc(app: ^App, v: ^Journal_View) -> (e: Journal_Entry, ok: bool) {
	d := v.details
	if d == nil || v.vl.sel < 0 { return }
	shown := journal_shown(app, v)
	if v.vl.sel >= len(shown) { return }
	return d.journal[shown[v.vl.sel]], true
}

// The selected entry whole, under the list: its date and time, its level, its program and process; its message
// wrapped, its text selectable.
@(private = "file")
journal_entry_whole :: proc(app: ^App, e: Journal_Entry, em: f32) {
	// (a height of its own: the list takes the rest. A longer message scrolls in it)
	ui.next({width = ui.fill(), height = ui.px(em * ENTRY_EM), axis = .Y, bg = surface("bar")})
	box := ui.build_box({.Draw_Background, .Draw_Side_Top, .Clip}, "###svc_journal_entry")
	if ui.parent(box) {
		ui.spacer(ui.px(em * 0.4))
		ui.next({width = ui.fill(), height = ui.px(em * 1.6)})
		if ui.row(.Center, {}, "###je_head") {
			ui.spacer(ui.px(em * 0.8))
			tag := JOURNAL_LEVEL_TAGS[e.priority]
			if tag != "" { ui.push_tags(tag) }
			ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("%s###je_level", JOURNAL_LEVEL_WORDS[e.priority]))
			if tag != "" { ui.pop_tags() }
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") {
				who := e.pid > 0 ? fmt.tprintf(i18n.tr("%s, process %d"), e.ident, e.pid) : e.ident
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s  ·  %s###je_info", journal_time_text(app, e.usec, true), ui.text_shown(who)))
			}
			if tool_button("svc_journal_copy_entry", lucide.CLIPBOARD_COPY, cmd_tip(.Journal_Copy_Entry), true, em) { platform.set_clipboard(app.main.win, journal_entry_text(app, e)); announce(app, i18n.tr("Copied the entry")) }
			ui.spacer(ui.px(em * 0.4))
		}
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		body := ui.build_box({.Clip, .View_Scroll_Y, .View_Clamp_Y, .Allow_Overflow_Y}, "###je_body")
		if ui.parent(body) {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###je_text") {
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.fill(), font_size = em * 0.95})
				ui.paragraph(fmt.tprintf("%s###je_message", ui.text_shown(e.message)))
				ui.spacer(ui.px(em * 0.8))
			}
		}
		ui.spacer(ui.px(em * 0.3))
	}
}

// "14:03:07", or with its date "2026-11-10 14:03:07", in local time.
journal_time_text :: proc(app: ^App, usec: i64, date: bool) -> string {
	if usec <= 0 { return "" }
	dt, ok := time.time_to_datetime(time.unix(usec / 1_000_000, 0))
	if !ok { return "" }
	if app.tz != nil { dt = timezone.datetime_to_tz(dt, app.tz) }
	if date { return fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d", dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second) }
	return fmt.tprintf("%02d:%02d:%02d", dt.hour, dt.minute, dt.second)
}

// An entry as one line of text: its date and time, its level, its program and process, its message.
@(private = "file")
journal_entry_text :: proc(app: ^App, e: Journal_Entry) -> string {
	who := e.pid > 0 ? fmt.tprintf("%s[%d]", e.ident, e.pid) : e.ident
	return fmt.tprintf("%s %s %s: %s", journal_time_text(app, e.usec, true), JOURNAL_LEVEL_WORDS[e.priority], who, e.message)
}

journal_level_set :: proc(app: ^App, l: Journal_Level) {
	app.settings.journal_level = l
	pref_set(&app.prefs, "services.journal_level", JOURNAL_LEVEL_KEYS[l])
	for v in journal_views(app) {
		v.vl.sel = -1
		ui.vlist_scroll_to(&v.vl, max(f32))
	}
	say(app, l == .All ? i18n.tr("The journal: every entry") : l == .Warnings ? i18n.tr("The journal: warnings and worse") : i18n.tr("The journal: errors and worse"))
}

journal_boot_set :: proc(app: ^App, boot: bool) {
	app.settings.journal_boot = boot
	pref_set(&app.prefs, "services.journal_boot", boot ? "true" : "false")
	// (each view read again, back to its end once read)
	app.services.pane.shown_for = 0
	if u, ok := selected_service(app); ok { details_ask(app, u.name) }
	for w in app.journals {
		w.view.shown_for = 0
		journal_view_ask(&w.view, w.manager, w.name, boot)
	}
	say(app, boot ? i18n.tr("The journal: this boot") : i18n.tr("The journal: every boot"))
}

// Whether a command of the journal can act now on the details': they are open, with entries for Copy.
journal_can :: proc(app: ^App, c: Cmd) -> bool {
	if !service_details_shown(app) || app.tab != .Services { return false }
	return journal_can_on(app, &app.services.pane, c)
}

// The journal's keys, read in a view that shows one (the details, a journal on its own) while it has the keyboard. The
// search keeps its editing keys; Escape there clears it first.
journal_keys :: proc(app: ^App, v: ^Journal_View) {
	if journal_search_escape(v) { return }
	field := v.search_key != 0 && ui.focus_key() == v.search_key
	for c in ([?]Cmd{.Journal_Search, .Journal_Level, .Journal_Boot, .Journal_Follow, .Journal_Copy, .Journal_Copy_Entry, .Journal_Window}) {
		// (Alt+C is no editing key; Ctrl+J in the search gives it the keyboard again: nothing to do)
		if field && c == .Journal_Search { continue }
		if ui.command_pressed(COMMANDS[c], !journal_can_on(app, v, c)) { journal_run_on(app, v, c) }
	}
}

journal_can_on :: proc(app: ^App, v: ^Journal_View, c: Cmd) -> bool {
	d := v.details
	#partial switch c {
	case .Journal_Copy:       return d != nil && len(d.journal) > 0
	case .Journal_Copy_Entry: _, ok := journal_selected(app, v); return ok
	case .Journal_Window:     return d != nil
	}
	return true
}

// A command of the journal, on the pane's.
journal_run :: proc(app: ^App, c: Cmd) { journal_run_on(app, &app.services.pane, c) }

journal_run_on :: proc(app: ^App, v: ^Journal_View, c: Cmd) {
	#partial switch c {
	case .Journal_Search: if v.search_key != 0 { ui.set_focus(v.search_key); ui.line_edit_select_all(&v.search) }
	case .Journal_Level:  journal_level_set(app, Journal_Level((int(app.settings.journal_level) + 1) % len(Journal_Level)))
	case .Journal_Boot:   journal_boot_set(app, !app.settings.journal_boot)
	case .Journal_Follow:
		app.settings.journal_follow = !app.settings.journal_follow
		pref_set(&app.prefs, "services.journal_follow", app.settings.journal_follow ? "true" : "false")
		for w in journal_views(app) { w.next = time.tick_now() }
		say(app, app.settings.journal_follow ? i18n.tr("Following the journal: new entries come in at the end") : i18n.tr("The journal is not read again"))
	case .Journal_Copy:
		d := v.details
		if d == nil { return }
		b := strings.builder_make(context.temp_allocator)
		shown := journal_shown(app, v)
		for i in shown { strings.write_string(&b, journal_entry_text(app, d.journal[i])); strings.write_byte(&b, '\n') }
		platform.set_clipboard(app.main.win, strings.to_string(b))
		announce(app, fmt.tprintf(i18n.tr(len(shown), "Copied %d entry", "Copied %d entries"), len(shown)))
	case .Journal_Copy_Entry:
		if e, ok := journal_selected(app, v); ok {
			platform.set_clipboard(app.main.win, journal_entry_text(app, e))
			announce(app, i18n.tr("Copied the entry"))
		}
	case .Journal_Window:
		if d := v.details; d != nil { journal_window_open(app, d.manager, d.name) }
	}
}

// Every journal shown: the details', then those on their own (temporary allocator).
journal_views :: proc(app: ^App) -> []^Journal_View {
	out := make([dynamic]^Journal_View, 0, 1 + len(app.journals), context.temp_allocator)
	append(&out, &app.services.pane)
	for w in app.journals { append(&out, &w.view) }
	return out[:]
}

// While the details follow the journal: the selected service's read again every JOURNAL_FOLLOW_MS (services_tick).
journal_follow_tick :: proc(app: ^App) {
	v := &app.services.pane
	if !service_details_seen(app) || !app.settings.journal_follow || app.paused { return }
	if time.tick_diff(v.next, time.tick_now()) < 0 || journal_view_busy(v) { return }
	v.next = time.tick_add(time.tick_now(), JOURNAL_FOLLOW_MS * time.Millisecond)
	if u, ok := selected_service(app); ok { details_ask(app, u.name) }
}

// The milliseconds until the followed journal is read again (max(int): it is not followed).
journal_due_ms :: proc(app: ^App) -> int {
	if !service_details_seen(app) || !app.settings.journal_follow || app.paused { return max(int) }
	return max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), app.services.pane.next))) + 1, 1)
}

// Escape in the journal's search: its text goes first, then the keyboard. (view_keys, before the commands' keys: the
// window's Escape is another command's)
journal_search_escape :: proc(v: ^Journal_View) -> bool {
	if v.search_key == 0 || ui.focus_key() != v.search_key || !ui.key_press(.Escape) { return false }
	if len(v.search.buf) > 0 { ui.line_edit_clear(&v.search) } else { ui.set_focus(0) }
	return true
}
