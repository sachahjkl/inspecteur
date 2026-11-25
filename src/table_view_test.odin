package inspecteur

import "core:math"
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
	// (one step of the scale between them, SPACE_1, on whole pixels as ui.space lays it)
	gap := math.round(name.font_size * ui.SPACE_1)
	testing.expectf(t, abs(count.rect.min.x - name.rect.max.x - gap) <= 1, "the count right after the name, %v apart: %v, %v", gap, name.rect.max.x, count.rect.min.x)
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

// At rest, a sample on Processes builds one frame and asks for no follow-up frame, animation or caret blink wake.
@(test)
processes_view_is_still_at_rest :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer catalog_destroy(&app.catalog)
	defer table_destroy(&app.table)
	defer sampler_destroy(&app.sampler)
	defer ranking_destroy(&app.ranking)
	defer ui.vlist_destroy(&app.vl)
	defer ui.line_edit_destroy(&app.search)

	app.settings.summary = true
	app.settings.refresh_ms = 1000
	table_columns_init(&app.table)
	catalog_add_entry(&app.catalog, "org.app.app0", "App 0", "", "app0", "")
	batch := [4]Proc_Counters{
		{pid = 10, ppid = 1, start = 100, comm = "app0", cpu_ns = 1000, threads = 1, private = 1024 * 1024},
		{pid = 11, ppid = 1, start = 101, comm = "bg1", cpu_ns = 2000, threads = 1, private = 2048 * 1024},
		{pid = 12, ppid = 1, start = 102, comm = "bg2", cpu_ns = 3000, threads = 1, private = 512 * 1024},
		{pid = 13, ppid = 1, start = 103, comm = "bg3", cpu_ns = 4000, threads = 1, private = 256 * 1024},
	}
	procs_merge(&app.sampler, batch[:], nil, 1.0, 10_000_000, &app.catalog, true, 1_000_000_000)
	table_group(&app.table, app.sampler.procs[:])
	rows_again(app)

	s := session.start(t, {size = {1100, 720}, user = app, no_renderer = true, build = proc(s: ^session.Session) {
		app := (^App)(s.user)
		app.shared.font = s.state.base_style.font
		build_processes(app, ui.font_size())
	}})
	session.frames(s, 3)
	testing.expect(t, !s.state.anim_busy, "no running animation at rest")
	testing.expect(t, !ui.needs_frame(s.state), "no extra frame needed at rest")
	testing.expectf(t, ui.wake_in_ms(s.state) <= 0, "no caret or timer wake at rest (got %d ms)", ui.wake_in_ms(s.state))

	// Steady sample with unchanged row identities must settle in a single frame without rebuilding vlist offsets.
	offsets_before := app.vl.offsets_made
	for &c in batch { c.cpu_ns += 500_000 }
	procs_merge(&app.sampler, batch[:], nil, 1.0, 10_000_000, &app.catalog, true, 2_000_000_000)
	table_group(&app.table, app.sampler.procs[:])
	rows_again(app)
	session.frames(s, 1)
	testing.expect(t, !s.state.anim_busy, "no animation started by steady sample")
	testing.expect(t, !ui.needs_frame(s.state), "single frame settles after steady sample")
	testing.expectf(t, ui.wake_in_ms(s.state) <= 0, "no extra wake after steady sample (got %d ms)", ui.wake_in_ms(s.state))
	testing.expect_value(t, app.vl.offsets_made, offsets_before)
}
