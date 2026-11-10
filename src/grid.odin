package inspecteur

// The table of the Services, Startup and Connections sections: its columns' titles (a click sorts, again reverses; the
// rule before a title, dragged, resizes the column), then its rows, only those in view built. It looks as the Processes
// table does (table_view.odin), with no groups.
//
// A section fills a Grid_Data when its reading changes: every cell's text, made once, and the number a numeric column
// sorts by. The grid filters and sorts row indices (grid_apply); the selection is kept by the row's identity.

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import lucide "gt:lucide"
import "gt:ui"

// Seconds the pointer rests on a cut cell before its whole text shows.
TIP_DELAY_S :: 0.5

Grid_Column :: struct {
	title:  string,
	width:  f32,    // in ems; 0: the room the others leave (one column has it)
	number: bool,   // right-aligned, sorted by its number, largest first at the first click
	weak:   bool,   // its text in the weak colour (details beside the name)
}

// How a row reads: plain, quiet (a unit that is not running), or a fault (a unit that failed).
Grid_Tone :: enum u8 { Normal, Dim, Bad }

// The icon before a row's first cell: an app's icon by its desktop entry's name, else a glyph of Lucide.
Grid_Icon :: struct {
	app:   string,
	glyph: string,
}

// What a section shows: its rows' texts and sort values, made anew with each reading (grid_data_reset).
Grid_Data :: struct {
	arena:  virtual.Arena,      // every text of the rows
	cols:   int,
	cells:  [dynamic]string,    // row by row
	nums:   [dynamic]f64,       // row by row: what a numeric column sorts by
	ids:    [dynamic]u64,
	search: [dynamic]string,    // what the filter looks in, in lower case
	icons:  [dynamic]Grid_Icon,
	tones:  [dynamic]Grid_Tone,
}

Grid :: struct {
	columns:    []Grid_Column,
	width:      []f32,           // the columns' widths now, in ems (owned)
	sort:       int,
	descending: bool,
	order:      [dynamic]int,    // the rows shown: filtered, sorted (indices of the data)
	ids:        [dynamic]u64,    // their identities (the list's keys)
	vl:         ui.Virtual_List,
	query:      string,          // the filter applied, in lower case (owned)
	sel_rect:   ui.Rect,         // the selected row, as last built (where the Menu key opens the menu)
}

grid_init :: proc(g: ^Grid, columns: []Grid_Column, sort := 0, descending := false) {
	g.columns = columns
	g.width = make([]f32, len(columns))
	for c, i in columns { g.width[i] = c.width }
	g.sort, g.descending = sort, descending
	g.vl.sel = -1
}

grid_destroy :: proc(g: ^Grid) {
	delete(g.width)
	delete(g.order)
	delete(g.ids)
	delete(g.query)
	ui.vlist_destroy(&g.vl)
}

grid_data_reset :: proc(d: ^Grid_Data, cols: int) {
	virtual.arena_destroy(&d.arena)
	d.arena = {}
	d.cols = cols
	clear(&d.cells)
	clear(&d.nums)
	clear(&d.ids)
	clear(&d.search)
	clear(&d.icons)
	clear(&d.tones)
}

grid_data_destroy :: proc(d: ^Grid_Data) {
	virtual.arena_destroy(&d.arena)
	delete(d.cells)
	delete(d.nums)
	delete(d.ids)
	delete(d.search)
	delete(d.icons)
	delete(d.tones)
	d^ = {}
}

grid_data_count :: proc(d: ^Grid_Data) -> int { return len(d.ids) }

// A new row; its cells follow (grid_cell, as many as the columns). `search`: what the filter finds it by.
grid_row :: proc(d: ^Grid_Data, id: u64, search: string, icon := Grid_Icon{}, tone := Grid_Tone.Normal) {
	a := virtual.arena_allocator(&d.arena)
	append(&d.ids, id)
	append(&d.search, strings.to_lower(search, a))
	append(&d.icons, Grid_Icon{app = strings.clone(icon.app, a), glyph = icon.glyph})
	append(&d.tones, tone)
}

grid_cell :: proc(d: ^Grid_Data, text: string, num: f64 = 0) {
	append(&d.cells, strings.clone(text, virtual.arena_allocator(&d.arena)))
	append(&d.nums, num)
}

grid_text :: proc(d: ^Grid_Data, row, col: int) -> string { return d.cells[row * d.cols + col] }

// The data row selected, -1 for none.
grid_selected :: proc(g: ^Grid) -> int {
	if g.vl.sel < 0 || g.vl.sel >= len(g.order) { return -1 }
	return g.order[g.vl.sel]
}

// Filters and sorts the rows again (new data, a new filter, a new sort); the same row stays selected when it is shown.
grid_apply :: proc(g: ^Grid, d: ^Grid_Data, query: string) {
	keep: u64
	has_keep := g.vl.sel >= 0 && g.vl.sel < len(g.ids)
	if has_keep { keep = g.ids[g.vl.sel] }
	if query != g.query {
		delete(g.query)
		g.query = strings.clone(query)
		g.vl.sel = -1
		has_keep = false
		ui.vlist_scroll_to(&g.vl, 0)
	}
	clear(&g.order)
	for i in 0 ..< len(d.ids) {
		if query == "" || strings.contains(d.search[i], query) { append(&g.order, i) }
	}
	Sort_Ctx :: struct { d: ^Grid_Data, col: int, number: bool }
	ctx := Sort_Ctx{d, g.sort, g.columns[g.sort].number}
	context.user_ptr = &ctx
	slice.sort_by(g.order[:], proc(a, b: int) -> bool {
		x := (^Sort_Ctx)(context.user_ptr)
		if x.number {
			na, nb := x.d.nums[a * x.d.cols + x.col], x.d.nums[b * x.d.cols + x.col]
			if na != nb { return na < nb }
		} else {
			c := compare_text(grid_text(x.d, a, x.col), grid_text(x.d, b, x.col))
			if c != 0 { return c < 0 }
		}
		// ties: by the first column, then as read
		c := compare_text(grid_text(x.d, a, 0), grid_text(x.d, b, 0))
		if c != 0 { return c < 0 }
		return a < b
	})
	if g.descending { slice.reverse(g.order[:]) }
	clear(&g.ids)
	for i in g.order { append(&g.ids, d.ids[i]) }
	ui.vlist_invalidate(&g.vl)
	g.vl.sel = -1
	if has_keep { for id, i in g.ids { if id == keep { g.vl.sel = i; break } } }
	if g.vl.sel < 0 && query != "" && len(g.ids) > 0 {
		g.vl.sel = 0
		g.vl.reveal = REVEAL_BUILDS
	}
}

// Selects the row of `id`, when it is shown.
grid_select_id :: proc(g: ^Grid, id: u64) -> bool {
	for v, i in g.ids {
		if v == id {
			g.vl.sel = i
			g.vl.reveal = REVEAL_BUILDS
			return true
		}
	}
	return false
}

// Compares two texts, case ignored (ASCII), then as they are.
compare_text :: proc(a, b: string) -> int {
	for i in 0 ..< min(len(a), len(b)) {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'Z' { x += 32 }
		if y >= 'A' && y <= 'Z' { y += 32 }
		if x != y { return int(x) - int(y) }
	}
	if len(a) != len(b) { return len(a) - len(b) }
	return strings.compare(a, b)
}

// The keys that move the selection (when no menu or dialog is open).
grid_keys :: proc(g: ^Grid) {
	n := len(g.ids)
	if n == 0 { return }
	to := g.vl.sel
	if ui.key_press(.Down) { to = g.vl.sel + 1 }
	if ui.key_press(.Up) { to = g.vl.sel < 0 ? 0 : g.vl.sel - 1 }
	if ui.key_press(.Page_Down) { to = g.vl.sel + PAGE_ROWS }
	if ui.key_press(.Page_Up) { to = g.vl.sel - PAGE_ROWS }
	if ui.key_press(.Home, {.Ctrl}) { to = 0 }
	if ui.key_press(.End, {.Ctrl}) { to = n - 1 }
	to = clamp(to, 0, n - 1)
	if to != g.vl.sel {
		g.vl.sel = to
		g.vl.reveal = REVEAL_BUILDS
	}
}

// What happened to the rows in a build.
Grid_Events :: struct {
	menu:      bool,   // a right click on a row (it is selected): its menu, at the mouse
	activated: bool,   // a double click on a row
	sorted:    bool,   // a title was clicked: the caller applies the rows again
}

// The header and the rows. `empty`: what the table says with no row (and no filter).
grid_build :: proc(app: ^App, g: ^Grid, d: ^Grid_Data, empty: string, em: f32) -> (ev: Grid_Events) {
	grid_header(app, g, &ev, em)
	row_h := ui.dense(em * ROW_EM)
	ui.next({width = ui.fill(), height = ui.fill()})
	rows, ok := ui.vlist("###rows", &g.vl, g.ids[:])
	if !ok { return }
	// (the filter has the keyboard, yet the selection is the window's: it shows as strong as a focused list's)
	g.vl.focused = true
	for i in rows.first ..< rows.last {
		r := g.order[i]
		ui.next({height = ui.px(row_h)})
		row := ui.list_row(&g.vl, i, grid_label(d, r))
		tip := ""
		if ui.parent(row.box) { tip = grid_cells(app, g, d, r, em) }
		// (a cell too narrow for its text: the whole text, once the pointer rests on it)
		if tip != "" && ui.hovered_for(row, TIP_DELAY_S) {
			if ui.tooltip_beside() { ui.tooltip_text(tip) }
		}
		if i == g.vl.sel { g.sel_rect = row.box.rect }
		if row.double_clicked { ev.activated = true }
		if row.right_clicked {
			g.vl.sel = i
			ev.menu = true
		}
	}
	if len(g.ids) == 0 {
		text := g.query != "" ? fmt.tprintf("Nothing matches “%s”.", shown_text(g.query)) : empty
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 5)})
			if ui.style({text_align = .Center}) { ui.label(fmt.tprintf("%s###empty", text)) }
		}
	}
	return
}

@(private = "file")
grid_header :: proc(app: ^App, g: ^Grid, ev: ^Grid_Events, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * HEADER_EM)), bg = surface("bar")})
	if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###header") {
		for c, k in g.columns {
			sorting := g.sort == k
			width := g.width[k] == 0 ? ui.fill() : ui.px(em * g.width[k])
			ui.next({width = width, height = ui.pct(1)})
			sig: ui.Signal
			if ui.row(.Center, {.Clickable, .Draw_Hot_Effects}, fmt.tprintf("###hd_%d", k)) {
				sig = ui.signal(ui.parent_box())
				if k > 0 && c.width > 0 { grid_rule(g, k, em) } else { ui.spacer(ui.px(em * (k == 0 ? 0.6 : RULE_GRIP_EM))) }
				if c.number { ui.spacer(ui.fill()) }
				if !sorting { ui.push_tags("weak") }
				ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###t", c.title))
				if !sorting { ui.pop_tags() }
				if !c.number { ui.spacer(ui.fill()) }
				if sorting {
					if ui.tags("weak") { glyph(app, g.descending ? lucide.ARROW_DOWN : lucide.ARROW_UP, em * 1.5) }
				} else {
					ui.spacer(ui.px(em * 0.6))
				}
			}
			if sig.clicked {
				if g.sort == k {
					g.descending = !g.descending
				} else {
					g.sort, g.descending = k, c.number
				}
				ev.sorted = true
			}
		}
		ui.spacer(ui.px(em * SCROLLBAR_EM))
	}
}

// The line before a column's title: dragged, the column grows or shrinks (the fill column takes what is left).
@(private = "file")
grid_rule :: proc(g: ^Grid, k: int, em: f32) {
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
	if sig.pressed { ui.drag_store({g.width[k], 0, 0, 0}) }
	if sig.dragging { g.width[k] = clamp(ui.drag_load()[0] - sig.drag_delta.x / em, COLUMN_MIN_EM, COLUMN_MAX_EM) }
}

// What a screen reader says of a row (and what live reads to know which row is selected): its first two cells.
grid_label :: proc(d: ^Grid_Data, r: int) -> string {
	if d.cols < 2 { return grid_text(d, r, 0) }
	return fmt.tprintf("%s, %s", grid_text(d, r, 0), grid_text(d, r, 1))
}

// The cells of a row. Returns the whole text of the cell under the pointer when it is cut.
@(private = "file")
grid_cells :: proc(app: ^App, g: ^Grid, d: ^Grid_Data, r: int, em: f32) -> (tip: string) {
	tone := d.tones[r]
	if tone == .Dim { ui.push_tags("weak") }
	if tone == .Bad { ui.push_tags("bad") }
	defer if tone != .Normal { ui.pop_tags() }
	for c, k in g.columns {
		text := shown_text(grid_text(d, r, k))
		width := g.width[k] == 0 ? ui.fill() : ui.px(em * g.width[k])
		if k == 0 {
			// the first column: the icon, then the text
			ui.next({width = width, height = ui.pct(1), axis = .X, cross = .Center})
			if ui.row(id = "###c_name") {
				ui.spacer(ui.px(em * 0.5))
				icon := d.icons[r]
				ic := icon.app != "" ? icon_of(&app.catalog, &app.app_icons, &app.shared.r, icon.app) : Icon{}
				if ic.ok {
					icon_box(ic, em * ICON_EM)
				} else if icon.glyph != "" {
					if ui.tags("weak") { glyph(app, icon.glyph, em * ICON_EM) }
				}
				ui.spacer(ui.px(em * 0.4))
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				b := ui.build_box({.Draw_Text, .Clip}, fmt.tprintf("%s###c0", text))
				if cut_under_mouse(app, b, text, 0, em) { tip = text }
			}
			continue
		}
		if c.weak && tone == .Normal { ui.push_tags("weak") }
		pad := c.number ? em * 0.6 : em * RULE_GRIP_EM * 0.5 + max(1, ui.scale())
		ui.next({width = width, height = ui.pct(1), text_align = c.number ? .Right : .Left, text_pad = pad})
		b := ui.build_box({.Draw_Text, .Clip}, fmt.tprintf("%s###c%d", text, k))
		if cut_under_mouse(app, b, text, pad, em) { tip = text }
		if c.weak && tone == .Normal { ui.pop_tags() }
	}
	ui.spacer(ui.px(em * SCROLLBAR_EM))
	return
}

// Whether the pointer is on the box and its text does not fit in it (the box as laid out at the last frame).
cut_under_mouse :: proc(app: ^App, b: ^ui.Box, text: string, pad, em: f32) -> bool {
	m := ui.mouse_pos()
	r := b.rect
	if m.x < r.min.x || m.x >= r.max.x || m.y < r.min.y || m.y >= r.max.y { return false }
	return ui.text_width(app.shared.font, em, text) + 2 * pad > r.max.x - r.min.x
}

////////////////////////////////
// A section's bar and its menu

// The bar of a section: its actions (built by `actions`), its title, a note (what it counts, that it reads), then what
// `right` builds at the right end (a choice of what is listed).
section_bar :: proc(app: ^App, title, note: string, em: f32, actions: proc(app: ^App, em: f32) = nil, right: proc(app: ^App, em: f32) = nil) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * BAR_EM))})
	if ui.row(.Center, {.Draw_Side_Bottom}, "###bar") {
		ui.spacer(ui.px(em * 0.4))
		if actions != nil {
			actions(app, em)
			vrule(em)
			ui.spacer(ui.px(em * 0.3))
		} else {
			ui.spacer(ui.px(em * 0.4))
		}
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
		ui.label(fmt.tprintf("%s###bar_title", title))
		ui.spacer(ui.px(em * 0.8))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.label(fmt.tprintf("%s###counts", note))
		}
		if right != nil {
			right(app, em)
			ui.spacer(ui.px(em * 0.6))
		}
	}
}
