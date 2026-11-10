package inspecteur

// The Processes tab: its bar (the counts, End task), the columns' header (click: sort; again: reverse), the rows
// (processes.odin): only those in view are built.

import "core:fmt"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:font"
import lucide "gt:lucide"
import "core:time"
import "core:time/timezone"
import "gt:render"
import "gt:ui"

// The indent of a group's process, the chevron's and the icon's width, in ems.
INDENT_EM  :: 1.6
CHEVRON_EM :: 1.4
ICON_EM    :: 1.5
// The colour of a busy cell, from green through yellow and orange to red as the load grows: the CPU % (of the machine)
// and the share of the memory at which it is red, the least it shows for (a quiet cell stays plain).
HEAT_CPU_FULL  :: 25.0
HEAT_MEM_FULL  :: 0.15
HEAT_GPU_FULL  :: 60.0   // percent of a GPU's time
HEAT_MIN       :: 0.04
// The hue (degrees: 0 red, 60 yellow, 120 green) at each step of the load, then the colour's saturation and value
// (sRGB): a turn of the hue goes through clear colours, where a mix of green and red would go through olive.
// Over a dark page the colours are deeper (a bright green there glares); yellow keeps a higher value at each step (a dim
// yellow is olive).
HEAT_HUES        := [?]f32{135, 55, 30, 2}
HEAT_VALUES_LIGHT := [?]f32{0.88, 0.97, 0.95, 0.90}
HEAT_VALUES_DARK  := [?]f32{0.60, 0.84, 0.80, 0.72}
HEAT_SATURATION_LIGHT :: 0.80
HEAT_SATURATION_DARK  :: 0.80
// How much of the hue is mixed into the page: a light load is paler. Over a dark page a faint mix is murky: it starts
// stronger there.
HEAT_MIX_MIN_DARK  :: f32(0.80)
HEAT_MIX_MIN_LIGHT :: f32(0.45)
HEAT_MIX_MAX       :: f32(1.0)
// A page darker than this (relative luminance) is a dark one.
HEAT_DARK_PAGE :: 0.1
// The outline of a busy cell: its colour this much darker (a cell stands apart from its neighbour of the same hue).
HEAT_BORDER_SHADE :: 0.55
// A background lighter than this (relative luminance, linear light: mid-grey) takes dark text, a darker one light text.
HEAT_TEXT_LUMINANCE :: 0.2
HEAT_TEXT_DARK      :: ui.Color{0.006, 0.006, 0.006, 1}
HEAT_TEXT_LIGHT     :: ui.Color{1, 1, 1, 1}

// A load's colour (0: green, 1: red), opaque, in linear light as the toolkit takes colours; `dark`: for a dark page.
heat_hue :: proc(heat: f32, dark := false) -> ui.Color {
	h := clamp(heat, 0, 1) * f32(len(HEAT_HUES) - 1)
	i := min(int(h), len(HEAT_HUES) - 2)
	f := h - f32(i)
	angle := HEAT_HUES[i] + (HEAT_HUES[i + 1] - HEAT_HUES[i]) * f
	values := dark ? HEAT_VALUES_DARK : HEAT_VALUES_LIGHT
	return hsv_color(angle, dark ? HEAT_SATURATION_DARK : HEAT_SATURATION_LIGHT, values[i] + (values[i + 1] - values[i]) * f)
}

// A colour of a hue (degrees), a saturation and a value in sRGB, as a linear colour.
hsv_color :: proc(hue, sat, value: f32) -> ui.Color {
	h := math.mod(hue, 360) / 60
	c := value * sat
	x := c * (1 - abs(math.mod(h, 2) - 1))
	r, g, b: f32
	switch {
	case h < 1: r, g, b = c, x, 0
	case h < 2: r, g, b = x, c, 0
	case h < 3: r, g, b = 0, c, x
	case h < 4: r, g, b = 0, x, c
	case h < 5: r, g, b = x, 0, c
	case:       r, g, b = c, 0, x
	}
	m := value - c
	return draw.srgb(r + m, g + m, b + m, 1)
}

// A busy cell's background (the hue mixed into the page, opaque), the text that reads on it and its outline, for a load
// `heat` (1: red) over the page `page`.
heat_colors :: proc(heat: f32, page: ui.Color) -> (bg, fg, border: ui.Color) {
	h := clamp(heat, 0, 1)
	dark := luminance(page) < HEAT_DARK_PAGE
	hue := heat_hue(h, dark)
	least := dark ? HEAT_MIX_MIN_DARK : HEAT_MIX_MIN_LIGHT
	bg = lerp_color(page, hue, least + (HEAT_MIX_MAX - least) * h)
	bg.a = 1
	fg = luminance(bg) > HEAT_TEXT_LUMINANCE ? HEAT_TEXT_DARK : HEAT_TEXT_LIGHT
	border = {bg.r * HEAT_BORDER_SHADE, bg.g * HEAT_BORDER_SHADE, bg.b * HEAT_BORDER_SHADE, 1}
	return
}

// The relative luminance of a linear colour.
luminance :: proc(c: ui.Color) -> f32 { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

lerp_color :: proc(a, b: ui.Color, t: f32) -> ui.Color {
	return {a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t}
}

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
	if app.settings.summary { summary_build(app, em) }
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
		cmd_button(app, "end_tree", lucide.GIT_FORK, .End_Tree, em)
		p := selected_proc(app)
		cmd_button(app, "suspend", p != nil && p.state == .Stopped ? lucide.PLAY : lucide.SQUARE, .Suspend, em)
		vrule(em)
		cmd_button(app, "properties", lucide.INFO, .Properties, em)
		cmd_button(app, "open_location", lucide.FOLDER_OPEN, .Open_Location, em)
		cmd_button(app, "copy_command", lucide.COPY, .Copy_Command, em)
		vrule(em)
		cmd_button(app, "tree_view", app.table.tree ? lucide.APP_WINDOW : lucide.LIST_TREE, .Tree_View, em)
		vrule(em)
		ui.spacer(ui.px(em * 0.3))
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
		ui.label("Processes###bar_title")
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			counts := fmt.tprintf("%s, %s", count_text(app.table.shown_apps, "app", "apps"), count_text(app.table.shown_background, "background process", "background processes"))
			if app.table.tree { counts = fmt.tprintf("%s, as a tree", count_text(app.table.shown_tree, "process", "processes")) }
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
	rows_look(app, &app.vl)
	ui.next({width = ui.fill(), height = ui.fill()})
	rows, ok := ui.vlist("###rows", &app.vl, t.ids[:], nil, t.selectable[:])
	if !ok { return }
	// (the search has the keyboard, yet the selection is the window's: it shows as strong as a focused list's)
	app.vl.focused = true
	page := ui.color("background")   // (the busy cells' tint is seen over it: their text is chosen for the mix)
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
		if ui.parent(row.box) { tip = build_cells(app, r, em, page) }
		ui.table_cell_tip(row, tip)
		if i == app.vl.sel { app.sel_rect = row.box.rect }
		if row.double_clicked { default_action(app) }
		if row.right_clicked {
			// (the list made it the active row; a right click on a marked row keeps the marks: the menu acts on them)
			app.vl.reveal = REVEAL_BUILDS
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
build_cells :: proc(app: ^App, r: Row, em: f32, page: ui.Color) -> (tip: string) {
	s := &app.sampler
	t := &app.table
	p: Proc
	cpu: f32
	private, resident, gpu_mem: u64
	gpu: f32
	read, write: f64
	threads: i32
	name: string
	icon_name := ""
	count := 0
	switch r.kind {
	case .Process:
		p = s.procs[r.index]
		cpu, private, resident, gpu_mem, read, write, threads, name = p.cpu, p.private, p.resident, p.gpu_mem, p.read_rate, p.write_rate, p.threads, p.name
		gpu = p.gpu
		// (in a group, the app's icon is the group's; in the tree, each app's process has its own)
		if p.entry >= 0 && (r.depth == 0 || t.tree) { icon_name = app.catalog.entries[p.entry].icon }
	case .App:
		g := t.groups[r.index]
		p = s.procs[g.root]
		e := app.catalog.entries[g.entry]
		cpu, private, resident, gpu_mem, read, write, threads, name = g.cpu, g.private, g.resident, g.gpu_mem, g.read_rate, g.write_rate, g.threads, e.name
		gpu = g.gpu
		icon_name = e.icon
		count = g.count
	case .Section:
		return
	}
	cell :: proc(t: ^Table, c: Column, text: string, tip: ^string, weak := false, heat: f32 = 0, page: ui.Color = {}) {
		bg, fg, border: Maybe(ui.Color)
		if heat >= HEAT_MIN { bg, fg, border = heat_colors(heat, page) }
		if weak && fg == nil { ui.push_tags("weak") }
		defer if weak && fg == nil { ui.pop_tags() }
		if ui.table_cell(&t.layout, int(c), text, bg, fg, border) { tip^ = text }
	}

	// Name: the indent, the chevron of a group, the icon, the name
	ui.next({width = ui.fill(), height = ui.pct(1), axis = .X, cross = .Center})
	if ui.row(id = "###c_name") {
		ui.spacer(ui.px(em * (0.3 + INDENT_EM * f32(r.depth))))
		if r.kind == .App || r.branch {
			open := t.query != "" || (r.kind == .App ? t.expanded[t.groups[r.index].key] : !t.collapsed[proc_key(p)])
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
			icon_box(ic, em * ICON_EM, app.icons)
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
		case .CPU:        cell(t, c, fmt.tprintf("%.1f%%", cpu), &tip, heat = cpu / HEAT_CPU_FULL, page = page)
		case .CPU_Graph:
			if text := cpu_graph_cell(app, r, page, em); text != "" { tip = text }
		case .Memory:     cell(t, c, size_text(private), &tip, heat = app.machine.mem.total > 0 ? f32(f64(private) / f64(app.machine.mem.total) / HEAT_MEM_FULL) : 0, page = page)
		case .Resident:   cell(t, c, size_text(resident), &tip, weak = true)
		case .GPU:        cell(t, c, gpu > 0 ? fmt.tprintf("%.0f%%", gpu) : "", &tip, heat = gpu / HEAT_GPU_FULL, page = page)
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

// The CPU graph's cell of a row: a bar per sample of the last CPU_GRAPH_POINTS, its height and colour the load's (a
// group's: the sum of its processes'). Returns its numbers when the pointer is on it (the row's tooltip).
@(private = "file")
cpu_graph_cell :: proc(app: ^App, r: Row, page: ui.Color, em: f32) -> (tip: string) {
	d := ui.frame_new(Cpu_Graph_Draw)
	d.dark = luminance(page) < HEAT_DARK_PAGE
	d.scale = ui.scale()
	buf: [CPU_GRAPH_POINTS]f32
	#partial switch r.kind {
	case .Process:
		p := &app.sampler.procs[r.index]
		if p.hist != nil { d.count = history_tail(&p.hist.cpu, d.values[:]) }
	case .App:
		g := app.table.groups[r.index]
		for m in app.table.members[g.first:][:g.count] {
			q := &app.sampler.procs[m]
			if q.hist == nil { continue }
			n := history_tail(&q.hist.cpu, buf[:])
			// (each process's points end at the same sample: the newest at the right)
			for k in 0 ..< n { d.values[CPU_GRAPH_POINTS - n + k] += buf[k] }
			d.count = max(d.count, n)
		}
		copy(d.values[:], d.values[CPU_GRAPH_POINTS - d.count:])
	}
	w := app.table.layout.width[int(Column.CPU_Graph)]
	ui.next({width = w == 0 ? ui.fill() : ui.px(em * w), height = ui.pct(1)})
	box := ui.custom(fmt.tprintf("###c%d", int(Column.CPU_Graph)), cpu_graph_draw, d, {.Clip})
	m := ui.mouse_pos()
	if d.count > 0 && m.x >= box.rect.min.x && m.x < box.rect.max.x && m.y >= box.rect.min.y && m.y < box.rect.max.y {
		sum, top: f32
		for v in d.values[:d.count] { sum += v; top = max(top, v) }
		tip = fmt.tprintf("CPU over the last %s: %.1f%% on average, %.1f%% at most", span_text(d.count, app.settings.refresh_ms), sum / f32(d.count), top)
	}
	return
}

@(private = "file")
Cpu_Graph_Draw :: struct {
	values: [CPU_GRAPH_POINTS]f32,
	count:  int,
	dark:   bool,
	scale:  f32,
}

// The height a bar takes at most (the rest is the cell's margin), and its least when the process used anything. A bar's
// height is the square root of its share of HEAT_CPU_FULL: the same scale on every row, and a light load still has a
// shape.
CPU_GRAPH_HEIGHT :: 0.66
CPU_GRAPH_LEAST  :: 0.05   // percent

@(private = "file")
cpu_graph_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Cpu_Graph_Draw)(user)
	r := b.rect
	pad := (r.max.x - r.min.x) * 0.06
	left, right := r.min.x + pad, r.max.x - pad
	h := (r.max.y - r.min.y) * CPU_GRAPH_HEIGHT
	bottom := math.round(r.max.y - (r.max.y - r.min.y - h) * 0.5)
	px := max(1, math.round(d.scale))
	slot := (right - left) / CPU_GRAPH_POINTS
	// (the newest at the right edge: a history not full yet starts on the right)
	first := CPU_GRAPH_POINTS - d.count
	for v, i in d.values[:d.count] {
		if v < CPU_GRAPH_LEAST { continue }
		x0 := math.round(left + slot * f32(first + i))
		x1 := max(x0 + px, math.round(left + slot * f32(first + i + 1)) - (slot >= 3 * px ? px : 0))
		top := bottom - max(px, math.round(h * math.sqrt(min(v / HEAT_CPU_FULL, 1))))
		draw.rect(dc, {{x0, top}, {x1, bottom}}, heat_hue(v / HEAT_CPU_FULL, d.dark))
	}
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

// An app's icon, `width` wide, the row's height: its texture, or a glyph on its tile (the demo's).
icon_box :: proc(ic: Icon, width: f32, glyph_font: font.Font_Id = 0) {
	d := ui.frame_new(Icon_Draw)
	d.tex, d.tile, d.tint = ic.tex, ic.glyph != "", ic.tint
	ui.next({width = ui.px(width), height = ui.pct(1)})
	box := ui.custom("###icon", icon_draw, d)
	if ic.glyph == "" { return }
	if ui.parent(box) {
		// (the glyph over the tile, white, centred: the box's own text)
		ui.next({width = ui.pct(1), height = ui.pct(1), font = glyph_font, font_size = ui.font_size() * 0.95, text_align = .Center, fg = ui.Color{1, 1, 1, 1}})
		ui.build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###glyph", ic.glyph))
	}
}

@(private = "file")
Icon_Draw :: struct { tex: render.Texture, tile: bool, tint: [4]f32 }

@(private = "file")
icon_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Icon_Draw)(user)
	h := b.rect.max.y - b.rect.min.y
	side := min(b.rect.max.x - b.rect.min.x, h * 0.72)
	at := ui.Vec2{b.rect.min.x + (b.rect.max.x - b.rect.min.x - side) * 0.5, b.rect.min.y + (h - side) * 0.5}
	if d.tile { draw.rect(dc, {at, at + side}, ui.Color(d.tint), side * 0.22); return }
	draw.image(dc, d.tex, {at, at + side})
}
