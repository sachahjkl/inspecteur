package inspecteur

// The Processes tab: its bar (the counts, End task), the columns' header (click: sort; again: reverse), the rows
// (processes.odin): only those in view are built.

import "core:fmt"
import "gt:draw"
import lucide "gt:lucide"
import "gt:render"
import "gt:ui"

// The width of each column but Name, in ems.
COLUMN_EM := [Column]f32{.Name = 0, .PID = 5.5, .User = 6.5, .CPU = 5.5, .Memory = 6.5, .Read = 7, .Write = 7, .Threads = 5.5}
// The indent of a group's process, the chevron's and the icon's width, in ems.
INDENT_EM  :: 1.6
CHEVRON_EM :: 1.4
ICON_EM    :: 1.5
// Room at the right of the last column for the rows' scroll bar, which floats over them, in ems.
SCROLLBAR_EM :: 1
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
@(private = "file")
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

// The columns' titles, a thin line between them; the sort's arrow at the right end of the sorted one.
@(private = "file")
build_header :: proc(app: ^App, em: f32) {
	t := &app.table
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * HEADER_EM)), bg = surface("bar")})
	if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###header") {
		for c in Column {
			right := c != .Name && c != .User
			sorting := t.sort == c
			width := c == .Name ? ui.fill() : ui.px(em * COLUMN_EM[c])
			ui.next({width = width, height = ui.pct(1)})
			sig: ui.Signal
			if ui.row(.Center, {.Clickable, .Draw_Hot_Effects}, fmt.tprintf("###hd_%d", int(c))) {
				sig = ui.signal(ui.parent_box())
				if c != .Name { vrule(em) } else { ui.spacer(ui.px(em * (0.3 + CHEVRON_EM))) }
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
			}
		}
		ui.spacer(ui.px(em * SCROLLBAR_EM))
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
		row := ui.list_row(&app.vl, i, "")
		if ui.parent(row.box) { build_cells(app, r, em, hot) }
		if i == app.vl.sel { app.sel_rect = row.box.rect }
		if row.double_clicked && r.kind == .App { group_toggle(app, r) }
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
	rss: u64
	read, write: f64
	threads: i32
	name: string
	icon_name := ""
	count := 0
	switch r.kind {
	case .Process:
		p = s.procs[r.index]
		cpu, rss, read, write, threads, name = p.cpu, p.rss, p.read_rate, p.write_rate, p.threads, p.name
		if p.entry >= 0 && r.depth == 0 { icon_name = app.catalog.entries[p.entry].icon }
	case .App:
		g := t.groups[r.index]
		p = s.procs[g.root]
		e := app.catalog.entries[g.entry]
		cpu, rss, read, write, threads, name = g.cpu, g.rss, g.read_rate, g.write_rate, g.threads, e.name
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
			d := ui.frame_new(Icon_Draw)
			d.tex = ic.tex
			ui.next({width = ui.px(em * ICON_EM), height = ui.pct(1)})
			ui.custom("###icon", icon_draw, d)
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

	weak := r.kind == .App   // (an app's pid and user are its first process's)
	cell(.PID, fmt.tprintf("%d", p.pid), em, weak = true)
	cell(.User, user_name(s, p.uid), em, weak = true)
	cell(.CPU, fmt.tprintf("%.1f%%", cpu), em, heat = cpu / HEAT_CPU_FULL, hot = hot)
	cell(.Memory, size_text(rss), em, heat = s.mem_total > 0 ? f32(f64(rss) / f64(s.mem_total) / HEAT_MEM_FULL) : 0, hot = hot)
	cell(.Read, (r.kind == .Process && p.io_denied) ? "–" : rate_text(read), em, weak = p.io_denied)
	cell(.Write, (r.kind == .Process && p.io_denied) ? "–" : rate_text(write), em, weak = p.io_denied)
	cell(.Threads, fmt.tprintf("%d", threads), em, weak = weak)
	ui.spacer(ui.px(em * SCROLLBAR_EM))
}

// A cell of a numeric or short column, its text under its title (the header's titles start after a line of em * 0.7).
// `heat` 0..1: how strongly its background is tinted (a busy process stands out).
@(private = "file")
cell :: proc(c: Column, text: string, em: f32, weak := false, heat: f32 = 0, hot: ui.Color = {}) {
	right := c != .User
	bg: Maybe(ui.Color)
	flags := ui.Box_Flags{.Draw_Text}
	if heat >= HEAT_MIN {
		tint := hot
		tint.a = HEAT_ALPHA * min(heat, 1)
		bg = tint
		flags += {.Draw_Background}
	}
	if weak { ui.push_tags("weak") }
	pad := right ? em * 0.6 : em * 0.7 + max(1, ui.scale())
	ui.next({width = ui.px(em * COLUMN_EM[c]), height = ui.pct(1), text_align = right ? .Right : .Left, text_pad = pad, bg = bg})
	ui.build_box(flags, fmt.tprintf("%s###c%d", text, int(c)))
	if weak { ui.pop_tags() }
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
