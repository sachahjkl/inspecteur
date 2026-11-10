package inspecteur

// The Processes tab: its bar (the counts, End task), the columns' header (click: sort; again: reverse), the rows
// (processes.odin): only those in view are built.

import "core:fmt"
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
// Room at the right of the last column for the rows' scroll bar, which floats over them, in ems.
SCROLLBAR_EM :: 1
// The grip of a column's rule, in ems: where a drag takes it.
RULE_GRIP_EM :: 0.7
// The columns shown by default (processes.columns' default says the same).
DEFAULT_COLUMNS :: bit_set[Column]{.Name, .PID, .User, .CPU, .Memory, .Read, .Write, .Threads}
// The tint of a busy cell (the theme's warning hue): the CPU % (of the machine) and the share of the memory at which it is
// strongest, the least it shows for (a quiet cell stays plain), and its strongest opacity.
HEAT_CPU_FULL :: 25.0
HEAT_MEM_FULL :: 0.15
HEAT_MIN      :: 0.04
HEAT_ALPHA    :: 0.3

build_processes :: proc(app: ^App, em: f32) {
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
		ui.spacer(ui.px(em * 0.4))
		p: ^Proc
		if r, ok := selected_row(app); ok { p, _ = row_process(app, r) }
		if tool_button(app, "end_task", lucide.X, "End task (Delete)", p != nil, em) { end_selected(app) }
		if tool_button(app, "kill", lucide.ZAP, "Kill (Shift+Delete)", p != nil, em) { kill_selected(app) }
		vrule(em)
		if tool_button(app, "open_location", lucide.FOLDER_OPEN, "Open file location", p != nil && p.exe != "", em) { open_location(app, p) }
		if tool_button(app, "copy_command", lucide.COPY, "Copy command line", p != nil && p.cmdline != "", em) { copy_command(app, p) }
		vrule(em)
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
		ui.label("Processes###bar_title")
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label(fmt.tprintf("%s, %s###counts", count_text(app.table.shown_apps, "app", "apps"), count_text(app.table.shown_background, "background process", "background processes")))
		}
	}
}

// A flat button with an icon of Lucide; its tooltip says what it does. A button that cannot act now is greyed.
tool_button :: proc(app: ^App, id, icon, tip: string, enabled: bool, em: f32) -> bool {
	sig: ui.Signal
	if ui.disabled(!enabled) {
		ui.next({width = ui.px(em * 2.2), height = ui.px(ui.dense(em * 2)), font = app.icons})
		if ui.tags("ghost_button") { sig = ui.button(fmt.tprintf("%s###%s", icon, id)) }
	}
	if ui.hovered_for(sig, 0.4) {
		if ui.tooltip() {
			ui.next({width = ui.text_size(em * 0.6), height = ui.px(ui.dense(em * 1.8))})
			ui.label(fmt.tprintf("%s###tip", tip))
		}
	}
	return sig.clicked && enabled
}

// The columns' titles, a rule before each (dragged: the column's width); the sort's arrow at the right end of the sorted
// one. A click sorts; a right click opens the menu of the columns.
@(private = "file")
build_header :: proc(app: ^App, em: f32) {
	t := &app.table
	picker := false
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * HEADER_EM)), bg = surface("bar")})
	if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom, .Clickable}, "###header") {
		picker = ui.signal(ui.parent_box()).right_clicked
		for c in Column {
			if !t.shown[c] { continue }
			right := c not_in COLUMN_TEXT
			sorting := t.sort == c
			width := c == .Name ? ui.fill() : ui.px(em * t.width[c])
			ui.next({width = width, height = ui.pct(1)})
			sig: ui.Signal
			if ui.row(.Center, {.Clickable, .Draw_Hot_Effects}, fmt.tprintf("###hd_%d", int(c))) {
				sig = ui.signal(ui.parent_box())
				if c != .Name { resize_rule(app, c, em) } else { ui.spacer(ui.px(em * (0.3 + CHEVRON_EM))) }
				if right { ui.spacer(ui.fill()) }
				if !sorting { ui.push_tags("weak") }
				ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###t", COLUMN_NAMES[c]))
				if !sorting { ui.pop_tags() }
				if !right { ui.spacer(ui.fill()) }
				if sorting {
					if ui.tags("weak") { glyph(app, t.descending ? lucide.ARROW_DOWN : lucide.ARROW_UP, em * 1.5) }
				} else {
					ui.spacer(ui.px(em * 0.6))
				}
			}
			if sig.clicked {
				table_sort_by(t, c)
				rows_again(app)
				table_layout_save(t, &app.prefs)
			}
			if sig.right_clicked { picker = true }
		}
		ui.spacer(ui.px(em * SCROLLBAR_EM))
	}
	if picker {
		if app.columns_menu == 0 { app.columns_menu = ui.key_from_string(0, "inspecteur_columns") }
		ui.ctx_menu_open(app.columns_menu, ui.mouse_pos())
	}
	columns_menu(app, em)
}

// The line before a column's title: dragged left or right, the column grows or shrinks (the name's column takes what is
// left); let go, the width is saved.
@(private = "file")
resize_rule :: proc(app: ^App, c: Column, em: f32) {
	t := &app.table
	ui.next({width = ui.px(em * RULE_GRIP_EM), height = ui.pct(1), cursor = .Resize_H})
	grip := ui.build_box({.Clickable}, "###rule")
	sig := ui.signal(grip)
	if ui.parent(grip) {
		ui.spacer(ui.fill())
		hot := grip.hot_t > 0 || sig.dragging
		ui.next({width = ui.px(max(1, ui.scale()) * (hot ? 2 : 1)), height = ui.px(em * 1.2), bg = hot ? ui.color("accent") : ui.color("border")})
		ui.build_box({.Draw_Background}, "###line")
		ui.spacer(ui.fill())
	}
	if sig.pressed { ui.drag_store({t.width[c], 0, 0, 0}) }
	if sig.dragging { t.width[c] = clamp(ui.drag_load()[0] - sig.drag_delta.x / em, COLUMN_MIN_EM, COLUMN_MAX_EM) }
	if sig.released { table_layout_save(t, &app.prefs) }
}

// The menu of the columns: each one but the name, shown or not; the defaults back.
@(private = "file")
columns_menu :: proc(app: ^App, em: f32) {
	t := &app.table
	if app.columns_menu == 0 { return }
	if ui.ctx_menu(app.columns_menu, em * 14) {
		ui.menu_heading("Columns")
		for c in Column {
			if c == .Name { continue }
			if ui.menu_item(COLUMN_NAMES[c], checked = t.shown[c], keep_open = true).clicked {
				t.shown[c] = !t.shown[c]
				if !t.shown[c] && t.sort == c { t.sort, t.descending = .Name, false; rows_again(app) }
				table_layout_save(t, &app.prefs)
			}
		}
		ui.menu_separator()
		if ui.menu_item("Default columns").clicked {
			for col in Column { t.shown[col], t.width[col] = col in DEFAULT_COLUMNS, COLUMN_DEFAULT_EM[col] }
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
		if ui.parent(row.box) { build_cells(app, r, em, hot) }
		if i == app.vl.sel { app.sel_rect = row.box.rect }
		if row.double_clicked { if r.kind == .App { group_toggle(app, r) } else { props_selected(app) } }
		if row.right_clicked {
			select_row(app, i)
			row_menu_open(app, ui.mouse_pos())
		}
	}
	if len(t.rows) == 0 && t.query != "" {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 5)})
			if ui.style({text_align = .Center}) { ui.label(fmt.tprintf("No process matches “%s”.###empty", shown_text(ui.field_string(&app.search)))) }
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
		return fmt.tprintf("%s, PID %d", shown_text(p.name), p.pid)
	case .App:
		g := app.table.groups[r.index]
		return fmt.tprintf("%s, %s", shown_text(app.catalog.entries[g.entry].name), count_text(g.count, "process", "processes"))
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

@(private = "file")
build_cells :: proc(app: ^App, r: Row, em: f32, hot: ui.Color) {
	s := &app.sampler
	t := &app.table
	p: Proc
	cpu: f32
	rss, gpu_mem: u64
	read, write: f64
	threads: i32
	name: string
	icon_name := ""
	count := 0
	switch r.kind {
	case .Process:
		p = s.procs[r.index]
		cpu, rss, gpu_mem, read, write, threads, name = p.cpu, p.rss, p.gpu_mem, p.read_rate, p.write_rate, p.threads, p.name
		if p.entry >= 0 && r.depth == 0 { icon_name = app.catalog.entries[p.entry].icon }
	case .App:
		g := t.groups[r.index]
		p = s.procs[g.root]
		e := app.catalog.entries[g.entry]
		cpu, rss, gpu_mem, read, write, threads, name = g.cpu, g.rss, g.gpu_mem, g.read_rate, g.write_rate, g.threads, e.name
		icon_name = e.icon
		count = g.count
	case .Section:
		return
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
				if ui.signal(chev).clicked && t.query == "" { group_toggle(app, r) }
			}
		} else {
			ui.spacer(ui.px(em * CHEVRON_EM))
		}
		ic := icon_of(&app.catalog, &app.app_icons, &app.shared.r, icon_name)
		if ic.ok {
			icon_box(ic, em * ICON_EM)
		} else if ui.tags("weak") {
			glyph(app, r.kind == .App ? lucide.APP_WINDOW : lucide.SQUARE_TERMINAL, em * ICON_EM)
		}
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
		ui.label(fmt.tprintf("%s###n", shown_text(name)))
		if count > 0 {
			if ui.tags("weak") {
				ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = em * 0.35})
				ui.label(fmt.tprintf("(%d)###k", count))
			}
		}
		ui.spacer(ui.fill())
	}

	weak := r.kind == .App   // (an app's pid, user and the like are its first process's)
	io_dash := r.kind == .Process && p.io_denied
	for c in Column {
		if c == .Name || !t.shown[c] { continue }
		w := t.width[c]
		switch c {
		case .Name:
		case .PID:        cell(c, w, fmt.tprintf("%d", p.pid), em, weak = true)
		case .PPID:       cell(c, w, fmt.tprintf("%d", p.ppid), em, weak = true)
		case .User:       cell(c, w, user_name(s, p.uid), em, weak = true)
		case .State:      cell(c, w, state_text(p.state), em, weak = p.state != 'T' && p.state != 'Z')
		case .Nice:       cell(c, w, fmt.tprintf("%d", p.nice), em, weak = p.nice == 0)
		case .CPU:        cell(c, w, fmt.tprintf("%.1f%%", cpu), em, heat = cpu / HEAT_CPU_FULL, hot = hot)
		case .Memory:     cell(c, w, size_text(rss), em, heat = app.machine.mem.total > 0 ? f32(f64(rss) / f64(app.machine.mem.total) / HEAT_MEM_FULL) : 0, hot = hot)
		case .GPU_Memory: cell(c, w, gpu_mem > 0 ? size_text(gpu_mem) : "", em)
		case .Read:       cell(c, w, io_dash ? "–" : rate_text(read), em, weak = io_dash)
		case .Write:      cell(c, w, io_dash ? "–" : rate_text(write), em, weak = io_dash)
		case .Threads:    cell(c, w, fmt.tprintf("%d", threads), em, weak = weak)
		case .Started:    cell(c, w, started_text(app, p.start), em, weak = true)
		case .Command:    cell(c, w, shown_text(p.cmdline), em, weak = true)
		case .Executable: cell(c, w, shown_text(p.exe), em, weak = true)
		}
	}
	ui.spacer(ui.px(em * SCROLLBAR_EM))
}

// A cell, its text under its title (the header's titles start after a rule of RULE_GRIP_EM). `heat` 0..1: how strongly
// its background is tinted (a busy process stands out).
@(private = "file")
cell :: proc(c: Column, width_em: f32, text: string, em: f32, weak := false, heat: f32 = 0, hot: ui.Color = {}) {
	right := c not_in COLUMN_TEXT
	bg: Maybe(ui.Color)
	flags := ui.Box_Flags{.Draw_Text, .Clip}
	if heat >= HEAT_MIN {
		tint := hot
		tint.a = HEAT_ALPHA * min(heat, 1)
		bg = tint
		flags += {.Draw_Background}
	}
	if weak { ui.push_tags("weak") }
	pad := right ? em * 0.6 : em * RULE_GRIP_EM * 0.5 + max(1, ui.scale())
	ui.next({width = ui.px(em * width_em), height = ui.pct(1), text_align = right ? .Right : .Left, text_pad = pad, bg = bg})
	ui.build_box(flags, fmt.tprintf("%s###c%d", text, int(c)))
	if weak { ui.pop_tags() }
}

// When a process started: its time today, else its date and time (local time).
started_text :: proc(app: ^App, start_ticks: u64) -> string {
	if app.machine.boot_time == 0 { return "" }
	if !app.tz_tried {
		app.tz_tried = true
		app.tz, _ = timezone.region_load("local")
	}
	at := time.unix(app.machine.boot_time + i64(start_ticks / CLOCK_TICKS), 0)
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
