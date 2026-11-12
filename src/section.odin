package inspecteur

// What the Services, Startup and Connections sections share: their table is the toolkit's (ui.Table: a section fills a
// ui.Table_Data with its cells' texts when its reading changes; the table filters and sorts the rows and keeps the
// selection by the row's identity), with the icon of each row before its first cell; and their bar.

import "core:fmt"
import "gt:ui"

// The icon before a row's first cell: the first of its names the icon theme has (an app's desktop entry's Icon=, then
// others: a service's own name, its family's), else a glyph of Lucide. The names are tried when the row is drawn: a
// table of a hundred rows looks up the dozen in view.
Row_Icon :: struct {
	app:   string,      // in the data's arena (ui.table_data_clone)
	alts:  [2]string,   // the theme's names after it, in order (in the arena)
	glyph: string,
}

// A section's table, its rows and their icons (one per data row, in the order of the rows).
Section_Table :: struct {
	table: ui.Table,
	data:  ui.Table_Data,
	icons: [dynamic]Row_Icon,
	app:   ^App,
	menu:  ui.Key,   // its header's menu
}

section_table_init :: proc(st: ^Section_Table, app: ^App, columns: []ui.Table_Column) {
	ui.table_init(&st.table, columns)
	st.app = app
	st.table.lead = row_icon_lead
	st.table.lead_user = st
}

section_table_destroy :: proc(st: ^Section_Table) {
	ui.table_destroy(&st.table)
	ui.table_data_destroy(&st.data)
	delete(st.icons)
}

// A new reading: the rows follow (section_row, then ui.table_data_cell for each column).
section_rows_reset :: proc(st: ^Section_Table, cols: int) {
	ui.table_data_reset(&st.data, cols)
	clear(&st.icons)
}

section_row :: proc(st: ^Section_Table, id: u64, search: string, icon := Row_Icon{}, tone := ui.Table_Tone.Normal) {
	ui.table_data_row(&st.data, id, search, tone)
	append(&st.icons, Row_Icon{
		app = ui.table_data_clone(&st.data, icon.app),
		alts = {ui.table_data_clone(&st.data, icon.alts[0]), ui.table_data_clone(&st.data, icon.alts[1])},
		glyph = icon.glyph,
	})
}

// The table, its header and its rows. `empty`: what it says with no row and no filter.
section_table_build :: proc(st: ^Section_Table, empty: string) -> ui.Table_Events {
	shown := st.table.query != "" ? fmt.tprintf("Nothing matches “%s”.", st.table.query) : empty
	st.table.header_bg = surface("bar")
	rows_look(st.app, &st.table.vl)
	ui.next({width = ui.fill(), height = ui.fill()})
	return ui.table_build("###table", &st.table, &st.data, shown)
}

// What the table's header asked: its menu (a right click), a column reset, unsorted, the columns shown, the defaults; the
// layout kept in `<section>.*`, the rows sorted again.
section_header_menu :: proc(st: ^Section_Table, ev: ui.Table_Events, section: string, em: f32) {
	app := st.app
	if st.menu == 0 { st.menu = ui.key_from_string(0, fmt.tprintf("inspecteur_%s_columns", section)) }
	if ev.columns { ui.ctx_menu_open(st.menu, ui.mouse_pos()) }
	if ui.ctx_menu(st.menu, em * 16) {
		changed, sorted := ui.table_menu_items(&st.table.layout)
		if sorted { ui.table_apply(&st.table, &st.data, app.query) }
		if changed { section_layout_save(&st.table, &app.prefs, section) }
	}
}

// The icon of data row `row`: its app's, else its glyph.
@(private = "file")
row_icon_lead :: proc(t: ^ui.Table, row: int, size: f32) {
	st := (^Section_Table)(t.lead_user)
	app := st.app
	icon := st.icons[row]
	ic: Icon
	for name in ([3]string{icon.app, icon.alts[0], icon.alts[1]}) {
		if name == "" { continue }
		if ic = icon_of(app, name); ic.ok { break }
	}
	if ic.ok {
		icon_box(ic, size, app.icons)
	} else if icon.glyph != "" {
		if ui.tags("weak") { glyph(app, icon.glyph, size) }
	} else {
		ui.spacer(ui.px(size))
	}
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
			label_tip(fmt.tprintf("%s###counts", ui.text_shown(note)), note)
		}
		if right != nil {
			right(app, em)
			ui.spacer(ui.px(em * 0.6))
		}
	}
}
