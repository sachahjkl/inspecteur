package inspecteur

// The Processes tab: its bar (the counts, End task), the columns' header (click: sort; again: reverse), the rows
// (processes.odin): only those in view are built.

import "core:fmt"
import "core:strings"
import "gt:draw"
import lucide "gt:lucide"
import "core:time"
import "core:time/timezone"
import "gt:render"
import "gt:ui"

// The indent of a group's process, the chevron's and the icon's width, in ems.
INDENT_EM  :: 1.6
CHEVRON_EM :: 1.4
ICON_EM    :: 1.5
// The tint of a busy cell (the theme's warning hue): the CPU % (of the machine) and the share of the memory at which it is
// strongest, the least it shows for (a quiet cell stays plain), and its strongest opacity.
HEAT_CPU_FULL :: 25.0
HEAT_MEM_FULL :: 0.15
HEAT_MIN      :: 0.04
HEAT_ALPHA    :: 0.3

build_processes :: proc(app: ^App, em: f32) {
	if app.table.query != app.query {
		delete(app.table.query)
		app.table.query = strings.clone(app.query)
		// a new search starts from its first process (rows_again)
		if app.query != "" {
			app.vl.sel = -1
			ui.vlist_scroll_to(&app.vl, 0)
		}
		rows_again(app)
	}
	build_bar(app, em)
	build_header(app, em)
	build_rows(app, em)
}

// The tab's bar: the actions on the selection, flat icons with their tooltips, then the tab's name and what the filter
// shows.
@(private = "file")
build_bar :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * BAR_EM))})
	if ui.row(.Center, {.Draw_Side_Bottom}, "###bar") {
		app.bar_rect = ui.parent_box().rect
		ui.spacer(ui.px(em * 0.4))
		cmd_button(app, "end_task", lucide.X, .End_Task, em)
		cmd_button(app, "kill", lucide.ZAP, .Kill, em)
		p := selected_proc(app)
		cmd_button(app, "suspend", p != nil && p.state == .Stopped ? lucide.PLAY : lucide.SQUARE, .Suspend, em)
		vrule(em)
		cmd_button(app, "properties", lucide.INFO, .Properties, em)
		cmd_button(app, "open_location", lucide.FOLDER_OPEN, .Open_Location, em)
		cmd_button(app, "copy_command", lucide.COPY, .Copy_Command, em)
		vrule(em)
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
		ui.label("Processes###bar_title")
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			counts := fmt.tprintf("%s, %s", count_text(app.table.shown_apps, "app", "apps"), count_text(app.table.shown_background, "background process", "background processes"))
			ui.next({width = ui.fill(), height = ui.pct(1)})
			label_tip(fmt.tprintf("%s###counts", counts), counts)
		}
	}
}

// A flat button with an icon of Lucide; its tooltip says what it does and its key. A button that cannot act now is
// greyed (its tooltip still says what it would do).
tool_button :: proc(app: ^App, id, icon, tip: string, enabled: bool, em: f32) -> bool {
	sig: ui.Signal
	if ui.disabled(!enabled) {
		ui.next({width = ui.px(em * 2.2), height = ui.px(ui.dense(em * 2)), font = app.icons})
		if ui.tags("ghost_button") { sig = ui.button(fmt.tprintf("%s###%s", icon, id)) }
	}
	tip_after(sig, tip)
	return sig.clicked && enabled
}

// The button of a command: greyed when it cannot act; clicked, it runs.
cmd_button :: proc(app: ^App, id, icon: string, c: Cmd, em: f32) {
	if tool_button(app, id, icon, cmd_tip(c), cmd_can(app, c), em) { cmd_run(app, c) }
}

// The columns' titles (the toolkit's header: a click sorts, again reverses; the rule before a title, dragged, resizes
// its column; a right click opens the menu of the columns).
@(private = "file")
build_header :: proc(app: ^App, em: f32) {
	t := &app.table
	ui.next({bg = surface("bar")})
	ev := ui.table_header("###header", &t.layout, 0.3 + CHEVRON_EM)
	if ev.sorted {
		rows_again(app)
		table_layout_save(t, &app.prefs)
	}
	if ev.resized { table_layout_save(t, &app.prefs) }
	if ev.menu {
		if app.columns_menu == 0 { app.columns_menu = ui.key_from_string(0, "inspecteur_columns") }
		ui.ctx_menu_open(app.columns_menu, ui.mouse_pos())
	}
	columns_menu(app, em)
}

// Opens the menu of the columns under the table's header (Ctrl+Shift+C).
columns_menu_open :: proc(app: ^App) {
	tab_show(app, .Processes)
	if app.columns_menu == 0 { app.columns_menu = ui.key_from_string(0, "inspecteur_columns") }
	// (under the header: the bar's rect, as the last layout made it, and the header's height)
	em := ui.font_size()
	ui.ctx_menu_open(app.columns_menu, {app.bar_rect.min.x + em * 2, app.bar_rect.max.y + ui.dense(em * HEADER_EM)}, from_keyboard = true)
}

// The menu of the columns: each one but the name, shown or not; the defaults back.
@(private = "file")
columns_menu :: proc(app: ^App, em: f32) {
	t := &app.table
	if app.columns_menu == 0 { return }
	if ui.ctx_menu(app.columns_menu, em * 14) {
		ui.menu_heading("Columns")
		changed, sorted := ui.table_column_items(&t.layout)
		if sorted { rows_again(app) }
		if changed { table_layout_save(t, &app.prefs) }
		ui.menu_separator()
		if ui.menu_item("Default columns").clicked {
			sort := t.layout.sort
			ui.table_layout_reset(&t.layout)
			// (the sort's column may be one the defaults hide: the rows go by name then)
			if !t.layout.shown[t.layout.sort] { t.layout.sort = int(Column.Name) }
			if t.layout.sort != sort { rows_again(app) }
			table_layout_save(t, &app.prefs)
		}
	}
}

@(private = "file")
build_rows :: proc(app: ^App, em: f32) {
	t := &app.table
	row_h := ui.dense(em * ROW_EM)
	ui.next({width = ui.fill(), height = ui.fill()})
	rows, ok := ui.vlist("###rows", &app.vl, t.ids[:], nil, t.selectable[:])
	if !ok { return }
	// (the search has the keyboard, yet the selection is the window's: it shows as strong as a focused list's)
	app.vl.focused = true
	ui.push_tags("warn")
	hot := ui.color("text")   // (the theme's warning hue: the busy cells' tint)
	ui.pop_tags()
	for i in rows.first ..< rows.last {
		r := t.rows[i]
		ui.next({height = ui.px(row_h)})
		if r.kind == .Section {
			row := ui.list_row(&app.vl, i, "", selectable = false)
			if ui.parent(row.box) { build_section(app, r, em) }
			continue
		}
		row := ui.list_row(&app.vl, i, row_label(app, r))
		tip := ""
		if ui.parent(row.box) { tip = build_cells(app, r, em, hot) }
		ui.table_cell_tip(row, tip)
		if i == app.vl.sel { app.sel_rect = row.box.rect }
		if row.double_clicked { default_action(app) }
		if row.right_clicked {
			select_row(app, i)
			row_menu_open(app, ui.mouse_pos())
		}
	}
	if len(t.rows) == 0 && t.query != "" {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 5)})
			if ui.style({text_align = .Center}) { ui.label(fmt.tprintf("No process matches “%s”.###empty", ui.text_shown(ui.field_string(&app.search)))) }
		}
	}
}

// What a screen reader says of a row (and what live reads to know which process is selected): "sleep, PID 1234",
// "Firefox, 12 processes".
@(private = "file")
row_label :: proc(app: ^App, r: Row) -> string {
	#partial switch r.kind {
	case .Process:
		p := app.sampler.procs[r.index]
		return fmt.tprintf("%s, PID %d", ui.text_shown(p.name), p.pid)
	case .App:
		g := app.table.groups[r.index]
		return fmt.tprintf("%s, %s", ui.text_shown(app.catalog.entries[g.entry].name), count_text(g.count, "process", "processes"))
	}
	return ""
}

@(private = "file")
build_section :: proc(app: ^App, r: Row, em: f32) {
	t := &app.table
	ui.spacer(ui.px(em * 0.8))
	text := r.index == 0 ? fmt.tprintf("Apps (%d)###sec", t.shown_apps) : fmt.tprintf("Background processes (%d)###sec", t.shown_background)
	ui.next({width = ui.fill(), height = ui.pct(1), font_size = em * 0.92, fg = ui.color("accent")})
	ui.label(text)
}

// The cells of a row. Returns the whole text of the cell under the pointer when it is cut.
@(private = "file")
build_cells :: proc(app: ^App, r: Row, em: f32, hot: ui.Color) -> (tip: string) {
	s := &app.sampler
	t := &app.table
	p: Proc
	cpu: f32
	private, resident, gpu_mem: u64
	read, write: f64
	threads: i32
	name: string
	icon_name := ""
	count := 0
	switch r.kind {
	case .Process:
		p = s.procs[r.index]
		cpu, private, resident, gpu_mem, read, write, threads, name = p.cpu, p.private, p.resident, p.gpu_mem, p.read_rate, p.write_rate, p.threads, p.name
		if p.entry >= 0 && r.depth == 0 { icon_name = app.catalog.entries[p.entry].icon }
	case .App:
		g := t.groups[r.index]
		p = s.procs[g.root]
		e := app.catalog.entries[g.entry]
		cpu, private, resident, gpu_mem, read, write, threads, name = g.cpu, g.private, g.resident, g.gpu_mem, g.read_rate, g.write_rate, g.threads, e.name
		icon_name = e.icon
		count = g.count
	case .Section:
		return
	}
	cell :: proc(t: ^Table, c: Column, text: string, tip: ^string, weak := false, heat: f32 = 0, hot: ui.Color = {}) {
		bg: Maybe(ui.Color)
		if heat >= HEAT_MIN {
			tint := hot
			tint.a = HEAT_ALPHA * min(heat, 1)
			bg = tint
		}
		if weak { ui.push_tags("weak") }
		if ui.table_cell(&t.layout, int(c), text, bg) { tip^ = text }
		if weak { ui.pop_tags() }
	}

	// Name: the indent, the chevron of a group, the icon, the name
	ui.next({width = ui.fill(), height = ui.pct(1), axis = .X, cross = .Center})
	if ui.row(id = "###c_name") {
		ui.spacer(ui.px(em * (0.3 + INDENT_EM * f32(r.depth))))
		if r.kind == .App {
			open := t.expanded[t.groups[r.index].key] || t.query != ""
			if ui.tags("weak") {
				ui.next({width = ui.px(em * CHEVRON_EM), height = ui.pct(1), font = app.icons, text_align = .Center})
				chev := ui.build_box({.Clickable, .Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###chev", open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT))
				csig := ui.signal(chev)
				if csig.clicked && t.query == "" { group_toggle(app, r) }
				tip_after(csig, t.query != "" ? "Open while the filter finds some of its processes" : open ? cmd_tip(.Close_Group) : cmd_tip(.Open_Group))
			}
		} else {
			ui.spacer(ui.px(em * CHEVRON_EM))
		}
		ic := icon_of(app, icon_name)
		if ic.ok {
			icon_box(ic, em * ICON_EM)
		} else if ui.tags("weak") {
			glyph(app, r.kind == .App ? lucide.APP_WINDOW : lucide.SQUARE_TERMINAL, em * ICON_EM)
		}
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
		ui.label(fmt.tprintf("%s###n", ui.text_shown(name)))
		if count > 0 {
			if ui.tags("weak") {
				ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = em * 0.35})
				ui.label(fmt.tprintf("(%d)###k", count))
			}
		}
		ui.spacer(ui.fill())
	}

	weak := r.kind == .App   // (an app's pid, user and the like are its first process's)
	io_dash := r.kind == .Process && !p.io_known
	for c in Column {
		if c == .Name || !t.layout.shown[int(c)] { continue }
		switch c {
		case .Name:
		case .PID:        cell(t, c, fmt.tprintf("%d", p.pid), &tip, weak = true)
		case .PPID:       cell(t, c, fmt.tprintf("%d", p.ppid), &tip, weak = true)
		case .User:       cell(t, c, p.user, &tip, weak = true)
		case .State:      cell(t, c, state_text(p.state), &tip, weak = p.state != .Stopped && p.state != .Zombie)
		case .Nice:       cell(t, c, fmt.tprintf("%d", p.nice), &tip, weak = p.nice == 0)
		case .CPU:        cell(t, c, fmt.tprintf("%.1f%%", cpu), &tip, heat = cpu / HEAT_CPU_FULL, hot = hot)
		case .Memory:     cell(t, c, size_text(private), &tip, heat = app.machine.mem.total > 0 ? f32(f64(private) / f64(app.machine.mem.total) / HEAT_MEM_FULL) : 0, hot = hot)
		case .Resident:   cell(t, c, size_text(resident), &tip, weak = true)
		case .GPU_Memory: cell(t, c, gpu_mem > 0 ? size_text(gpu_mem) : "", &tip)
		case .Read:       cell(t, c, io_dash ? "–" : rate_text(read), &tip, weak = io_dash)
		case .Write:      cell(t, c, io_dash ? "–" : rate_text(write), &tip, weak = io_dash)
		case .Threads:    cell(t, c, fmt.tprintf("%d", threads), &tip, weak = weak)
		case .Started:    cell(t, c, started_text(app, p.started), &tip, weak = true)
		case .Command:    cell(t, c, p.cmdline, &tip, weak = true)
		case .Executable: cell(t, c, p.exe, &tip, weak = true)
		}
	}
	ui.table_row_end()
	return
}

// When a process started (unix seconds): its time today, else its date and time (local time).
started_text :: proc(app: ^App, started: i64) -> string {
	if started <= 0 { return "" }
	if !app.tz_tried {
		app.tz_tried = true
		app.tz, _ = timezone.region_load("local")
	}
	at := time.unix(started, 0)
	when_dt, ok := time.time_to_datetime(at)
	now_dt, nok := time.time_to_datetime(time.now())
	if !ok || !nok { return "" }
	if app.tz != nil {
		when_dt = timezone.datetime_to_tz(when_dt, app.tz)
		now_dt = timezone.datetime_to_tz(now_dt, app.tz)
	}
	if when_dt.date == now_dt.date { return fmt.tprintf("%02d:%02d:%02d", when_dt.hour, when_dt.minute, when_dt.second) }
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d", when_dt.year, when_dt.month, when_dt.day, when_dt.hour, when_dt.minute)
}

// An app's icon, `width` wide, the row's height.
icon_box :: proc(ic: Icon, width: f32) {
	d := ui.frame_new(Icon_Draw)
	d.tex = ic.tex
	ui.next({width = ui.px(width), height = ui.pct(1)})
	ui.custom("###icon", icon_draw, d)
}

@(private = "file")
Icon_Draw :: struct { tex: render.Texture }

@(private = "file")
icon_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Icon_Draw)(user)
	h := b.rect.max.y - b.rect.min.y
	side := min(b.rect.max.x - b.rect.min.x, h * 0.72)
	at := ui.Vec2{b.rect.min.x + (b.rect.max.x - b.rect.min.x - side) * 0.5, b.rect.min.y + (h - side) * 0.5}
	draw.image(dc, d.tex, {at, at + side})
}
