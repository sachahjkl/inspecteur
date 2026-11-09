package inspecteur

// The window's interface: the title bar is the window's own (the search, the window's buttons), the tabs, the tab, then a
// status bar. The Processes tab: End task beside the tabs, the columns' headers (click: sort; again: reverse), the
// rows (processes.odin).
//
//   typing                    filters (name, command line, pid)
//   Up / Down, Page Up / Page Down, Ctrl+Home / Ctrl+End    move
//   Right / Left, Enter       open / close an app's group (Right and Left when the search is empty)
//   Delete                    End task (SIGTERM)
//   Shift+Delete              Kill (SIGKILL), after a confirmation
//   a right click, Menu, Shift+F10    the row's menu (menu.odin)
//   Ctrl+Tab, Ctrl+Shift+Tab  the next, the previous tab
//   Escape                    clear the search

import "core:fmt"
import "core:slice"
import "core:strings"
import "gt:draw"
import "gt:host"
import "gt:render"
import lucide "gt:lucide"
import "gt:ui"

// Heights in ems: the title bar, the tabs, the header, a row, the status bar.
TITLE_EM   :: 2.6
TABS_EM :: 2.6
HEADER_EM  :: 2.9
ROW_EM     :: 1.85
STATUS_EM  :: 1.9
SEARCH_EM  :: 22   // the search field's width
// The width of each column but Name, in ems.
COLUMN_EM := [Column]f32{.Name = 0, .PID = 5, .User = 6.5, .CPU = 5, .Memory = 6.5, .Read = 6.5, .Write = 6.5, .Threads = 5}
// The indent of a group's process, the chevron's and the icon's width, in ems.
INDENT_EM  :: 1.6
CHEVRON_EM :: 1.4
ICON_EM    :: 1.5
// Room at the right of the last column for the rows' scroll bar, which floats over them, in ems.
SCROLLBAR_EM :: 1
// Rows Page Up / Page Down move by.
PAGE_ROWS :: 15
// Builds a selected row is pulled into view for (as the list's own keys do).
REVEAL_BUILDS :: 3
// The tint of a busy cell (the theme's warning hue): the CPU % (of the machine) and the share of the memory at which it is
// strongest, the least it shows for (a quiet cell stays plain), and its strongest opacity.
HEAT_CPU_FULL :: 25.0
HEAT_MEM_FULL :: 0.15
HEAT_MIN      :: 0.04
HEAT_ALPHA    :: 0.35

view_build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	em := ui.font_size()
	// the keyboard is the search's: typing anywhere filters
	if !app.menu.kill_open && app.search_key != 0 && ui.focus_key() != app.search_key { ui.set_focus(app.search_key) }
	if !app.menu.kill_open && !ui.ctx_menu_any_open() { view_keys(app) }
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.Draw_Background}, "###page")
	if ui.parent(page) {
		build_title(app, em)
		ui.hline(ui.fill())
		build_tabs(app, em)
		ui.hline(ui.fill())
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###tab") {
			if app.tab == .Processes { build_processes(app, em) } else { build_placeholder(app, em) }
		}
		ui.hline(ui.fill())
		build_status(app, em)
	}
	row_menu_build(app, em)
	ui.wake_within(&app.main.state, until_sample(app))
}

@(private = "file")
view_keys :: proc(app: ^App) {
	if ui.key_press(.Tab, {.Ctrl}) { app.tab = Tab((int(app.tab) + 1) % len(Tab)) }
	if ui.key_press(.Tab, {.Ctrl, .Shift}) { app.tab = Tab((int(app.tab) + len(Tab) - 1) % len(Tab)) }
	if app.tab != .Processes { return }
	if ui.key_press(.Down) { select_step(app, app.vl.sel, 1, 1) }
	if ui.key_press(.Up) { select_step(app, app.vl.sel, -1, 1) }
	if ui.key_press(.Page_Down) { select_step(app, app.vl.sel, 1, PAGE_ROWS) }
	if ui.key_press(.Page_Up) { select_step(app, app.vl.sel, -1, PAGE_ROWS) }
	if ui.key_press(.Home, {.Ctrl}) { select_step(app, -1, 1, 1) }
	if ui.key_press(.End, {.Ctrl}) { select_step(app, len(app.table.rows), -1, 1) }
	if ui.key_press(.Delete) { end_selected(app) }
	if ui.key_press(.Delete, {.Shift}) { kill_selected(app) }
	if ui.key_press(.Menu) || ui.key_press(.F10, {.Shift}) { row_menu_open(app, {app.sel_rect.min.x + 40, app.sel_rect.max.y}, from_keyboard = true) }
	if ui.key_press(.Escape) { ui.field_clear(&app.search) }
	r, ok := selected_row(app)
	if !ok { return }
	if ui.key_press(.Return) && r.kind == .App { group_toggle(app, r) }
	if len(app.search.buf) == 0 {
		if r.kind == .App && ui.key_press(.Right) && !app.table.expanded[app.table.groups[r.index].key] { group_toggle(app, r) }
		if ui.key_press(.Left) {
			if r.kind == .App && app.table.expanded[app.table.groups[r.index].key] { group_toggle(app, r) }
			if r.kind == .Process && r.depth > 0 { for i := app.vl.sel; i >= 0; i -= 1 { if app.table.rows[i].kind == .App { select_row(app, i); break } } }
		}
	}
}

// Moves the selection `count` rows from `from` in `dir`, over the section rows.
@(private = "file")
select_step :: proc(app: ^App, from, dir, count: int) {
	n := len(app.table.rows)
	at, left := from, count
	for k := from + dir; k >= 0 && k < n && left > 0; k += dir {
		if app.table.selectable[k] { at = k; left -= 1 }
	}
	if at >= 0 && at < n && at != from { select_row(app, at) }
}

select_row :: proc(app: ^App, row: int) {
	app.vl.sel = row
	app.vl.reveal = REVEAL_BUILDS
}

// Opens or closes an app's group; the selection stays on it.
@(private = "file")
group_toggle :: proc(app: ^App, r: Row) {
	key := app.table.groups[r.index].key
	if app.table.expanded[key] { delete_key(&app.table.expanded, key) } else { app.table.expanded[key] = true }
	rows_again(app)
	app.vl.reveal = REVEAL_BUILDS
}

////////////////////////////////
// The title bar and the tabs

// An icon of Lucide, `width` wide.
glyph :: proc(app: ^App, g: string, width: f32, fg: Maybe(ui.Color) = nil) {
	ui.next({width = ui.px(width), height = ui.pct(1), font = app.icons, text_align = .Center, fg = fg})
	ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###g%d", g, ui.parent_box().child_count))
}

@(private = "file")
build_title :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * TITLE_EM))})
	if ui.title_bar("###titlebar") {
		ui.spacer(ui.px(em * 0.5))
		glyph(app, lucide.EYE, em * 1.7, ui.color("accent"))
		ui.next({width = ui.text_size(em * 0.4), height = ui.pct(1)})
		ui.label("Inspecteur###apptitle")
		ui.spacer(ui.fill())
		build_search(app, em)
		ui.spacer(ui.fill())
		_, _ = ui.window_buttons()
	}
}

// The search, in the middle of the title bar: it has the keyboard, typing anywhere filters the processes.
@(private = "file")
build_search :: proc(app: ^App, em: f32) {
	ui.next({width = ui.px(em * SEARCH_EM), height = ui.px(ui.dense(em * 1.9))})
	if ui.field_frame("###searchbox") {
		if ui.tags("weak") { glyph(app, lucide.SEARCH, em * 1.8) }
		ui.next({width = ui.fill(), height = ui.pct(1)})
		if ui.tags("bare") {
			res := ui.line_edit("###search", &app.search, "Type to filter: name, command line, PID")
			app.search_key = res.box.key
		}
	}
	if q := strings.to_lower(ui.field_string(&app.search), context.temp_allocator); q != app.table.query {
		delete(app.table.query)
		app.table.query = strings.clone(q)
		app.tab = .Processes
		// a new search starts from its first process (rows_again)
		if q != "" {
			app.vl.sel = -1
			ui.vlist_scroll_to(&app.vl, 0)
		}
		rows_again(app)
	}
}

// The tabs, and what the tab shown offers beside them.
@(private = "file")
build_tabs :: proc(app: ^App, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * TABS_EM))})
	if ui.row(.Center, id = "###tabs") {
		ui.spacer(ui.px(em * 0.3))
		labels := TAB_LABELS
		icons := TAB_ICONS
		sel := int(app.tab)
		if ui.tabs("tab", slice.enumerated_array(&labels), slice.enumerated_array(&icons), &sel) { app.tab = Tab(sel) }
		ui.spacer(ui.fill())
		if app.tab == .Processes {
			if ui.tags("weak") {
				ui.next({width = ui.text_size(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s, %s###counts", count_text(app.table.shown_apps, "app", "apps"), count_text(app.table.shown_background, "background process", "background processes")))
			}
			ui.spacer(ui.px(em * 0.8))
			_, has := selected_row(app)
			ui.next({height = ui.px(ui.dense(em * 1.9))})
			if ui.button_icon("end_task", lucide.X, "End task", disabled = !has).clicked { end_selected(app) }
		}
		ui.spacer(ui.px(em * 0.6))
	}
}

@(private = "file")
build_placeholder :: proc(app: ^App, em: f32) {
	ui.spacer(ui.px(em * 4))
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(em * 2)})
		if ui.style({text_align = .Center}) { ui.label(fmt.tprintf("%s comes in a later version of Inspecteur.###placeholder", TAB_LABELS[app.tab])) }
	}
}

////////////////////////////////
// The Processes tab

@(private = "file")
build_processes :: proc(app: ^App, em: f32) {
	build_header(app, em)
	build_rows(app, em)
}

// The headers: the column's total above its name (the machine's CPU and memory, the disk's rates, the threads).
@(private = "file")
build_header :: proc(app: ^App, em: f32) {
	s := &app.sampler
	t := &app.table
	threads: i32
	read, write: f64
	for p in s.procs { threads += p.threads; read += p.read_rate; write += p.write_rate }
	totals := [Column]string{
		.Name = fmt.tprintf("%d processes", len(s.procs)), .PID = "", .User = "",
		.CPU = fmt.tprintf("%.0f%%", s.cpu),
		.Memory = fmt.tprintf("%.0f%%", s.mem_total > 0 ? 100 * f64(s.mem_used) / f64(s.mem_total) : 0),
		.Read = rate_text(read), .Write = rate_text(write), .Threads = fmt.tprintf("%d", threads),
	}
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * HEADER_EM))})
	if ui.tags("bar") {
		if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###header") {
			for c in Column {
				right := c != .Name && c != .User
				sorting := t.sort == c
				width := c == .Name ? ui.fill() : ui.px(em * COLUMN_EM[c])
				ui.next({width = width, height = ui.pct(1), axis = .Y})
				hd := ui.build_box({.Clickable, .Draw_Hot_Effects}, fmt.tprintf("###hd_%d", int(c)))
				if ui.parent(hd) {
					pad := c == .Name ? em * (CHEVRON_EM + 0.5) : em * 0.6
					ui.spacer(ui.fill())
					ui.next({width = ui.fill(), height = ui.px(em * 1.35), font_size = em * 1.12, text_align = right ? .Right : .Left, text_pad = pad})
					ui.label(fmt.tprintf("%s###tot", totals[c]))
					ui.next({width = ui.fill(), height = ui.px(em * 1.2), axis = .X, cross = .Center})
					if ui.row(id = "###name") {
						if right { ui.spacer(ui.fill()) } else { ui.spacer(ui.px(pad)) }
						if !sorting { ui.push_tags("weak") }
						ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0, font_size = em * 0.9})
						ui.label(COLUMN_NAMES[c])
						if !sorting { ui.pop_tags() }
						if sorting {
							glyph(app, t.descending ? lucide.CHEVRON_DOWN : lucide.CHEVRON_UP, em * 1.1, ui.color("accent"))
						}
						if right { ui.spacer(ui.px(sorting ? em * 0.3 : em * 0.6)) }
					}
					ui.spacer(ui.fill())
				}
				if ui.signal(hd).clicked {
					table_sort_by(t, c)
					rows_again(app)
				}
			}
			ui.spacer(ui.px(em * SCROLLBAR_EM))
		}
	}
}


@(private = "file")
build_rows :: proc(app: ^App, em: f32) {
	t := &app.table
	s := &app.sampler
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
	_ = s
}

@(private = "file")
build_section :: proc(app: ^App, r: Row, em: f32) {
	t := &app.table
	ui.spacer(ui.px(em * 0.7))
	text := r.index == 0 ? fmt.tprintf("Apps (%d)###sec", t.shown_apps) : fmt.tprintf("Background processes (%d)###sec", t.shown_background)
	if ui.tags("accent") {
		ui.next({width = ui.fill(), height = ui.pct(1), font_size = em * 0.92, fg = ui.color("accent")})
		ui.label(text)
	}
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
		ui.spacer(ui.px(em * 0.45))
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

// A cell of a numeric or short column. `heat` 0..1: how strongly its background is tinted (a busy process stands out).
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
	ui.next({width = ui.px(em * COLUMN_EM[c]), height = ui.pct(1), text_align = right ? .Right : .Left, text_pad = em * 0.6, bg = bg})
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

@(private = "file")
build_status :: proc(app: ^App, em: f32) {
	s := &app.sampler
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * STATUS_EM))})
	if ui.row(.Center, id = "###status") {
		ui.spacer(ui.px(em * 0.7))
		if ui.style({font_size = em * 0.9}) {
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.pct(1)})
				msg := app.status
				if msg == "" || ui.now_ms() > app.status_until {
					msg = fmt.tprintf("CPU %.0f%% of %d cores · Memory %s of %s · %d processes", s.cpu, s.cores, size_text(s.mem_used), size_text(s.mem_total), len(s.procs))
				}
				ui.label(fmt.tprintf("%s###msg", msg))
				if r, ok := selected_row(app); ok {
					if p, has := row_process(app, r); has {
						ui.next({width = ui.text_size(), height = ui.pct(1)})
						ui.label(fmt.tprintf("Selected: %s, PID %d###sel", shown_text(p.name), p.pid))
						ui.spacer(ui.px(em * 0.8))
					}
				}
				hints := [?][2]string{{"Del", "end task"}, {"Menu", "more"}}
				for hint in hints {
					ui.kbd(hint[0])
					ui.next({width = ui.text_size(em * 0.3), height = ui.pct(1)})
					ui.label(fmt.tprintf("%s###h%s", hint[1], hint[0]))
					ui.spacer(ui.px(em * 0.4))
				}
			}
		}
		ui.spacer(ui.px(em * 0.3))
	}
}

// Text to show as it is: a "##" in it would end the shown part of a box's id string (ui's key rules), so a zero-width
// space goes between the two signs.
shown_text :: proc(text: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(text, "##") { return text }
	out, _ := strings.replace_all(text, "##", "#​#", allocator)
	return out
}

// "1 app", "3 apps".
count_text :: proc(n: int, one, many: string) -> string { return fmt.tprintf("%d %s", n, n == 1 ? one : many) }
