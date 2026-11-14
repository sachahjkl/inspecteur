package inspecteur

import "core:testing"
import "gt:testkit/session"
import "gt:ui"

// An app's row, its Name column with room: the name whole, its count and its window's button right after it. In a column
// too narrow, the name alone is cut; the count stays whole. (A fill() spacer after them made the name share the row's
// excess with it: "Bul…" with the column half empty, "…" alone on a process under a group.)
@(test)
a_name_is_whole_when_its_column_has_room :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer catalog_destroy(&app.catalog)
	defer table_destroy(&app.table)
	defer delete(app.sampler.procs)
	defer delete(app.windows)
	catalog_add_entry(&app.catalog, "chat", "Messagerie instantanée", "", "chat", "")
	append(&app.sampler.procs, Proc{pid = 10, ppid = 1, entry = 0, name = "chat", search = "chat"}, Proc{pid = 11, ppid = 10, entry = -1, name = "chat-helper", search = "chat-helper"})
	append(&app.windows, App_Window{entry = 0})
	table_columns_init(&app.table)
	table_group(&app.table, app.sampler.procs[:])
	testing.expect_value(t, app.table.groups[0].count, 2)
	app.table.layout.width[int(Column.Name)] = 24   // ems: room for the name, its count and its button

	s := session.start(t, {size = {1600, 300}, user = app, no_renderer = true, build = proc(s: ^session.Session) {
		app := (^App)(s.user)
		em := ui.font_size()
		ui.next({width = ui.fill(), height = ui.px(em * ROW_EM)})
		if ui.row(.Center, id = "###row") { _ = build_cells(app, Row{kind = .App, index = 0}, em, ui.color("background")) }
	}})
	session.frames(s, 2)
	cell := session.get(s, "c_name")
	name := session.get(s, "n", within = cell)
	count := session.get(s, "k", within = cell)
	win := session.get(s, "win", within = cell)
	testing.expectf(t, name.size.x >= name.text_dim.x, "the name whole: %v of %v", name.size.x, name.text_dim.x)
	testing.expectf(t, abs(count.rect.min.x - name.rect.max.x) <= 1, "the count right after the name: %v, %v", name.rect.max.x, count.rect.min.x)
	testing.expectf(t, win.rect.min.x >= count.rect.max.x && win.rect.max.x <= cell.rect.max.x + 1, "the button after the count, in the cell: %v", win.rect)

	// (narrower than the name, its count and its button: the name is cut, not the count)
	app.table.layout.width[int(Column.Name)] = 11
	session.frames(s, 2)
	cell = session.get(s, "c_name")
	name = session.get(s, "n", within = cell)
	count = session.get(s, "k", within = cell)
	testing.expectf(t, name.size.x < name.text_dim.x && name.size.x > 0, "the name cut, some of it shown: %v of %v", name.size.x, name.text_dim.x)
	testing.expectf(t, count.size.x >= count.text_dim.x, "the count whole: %v of %v", count.size.x, count.text_dim.x)
}
