package inspecteur

// The acts on several rows: the processes chosen from the rows selected (by their ids: a new sample keeps them), the
// services an action means something for among those selected, the processes of the sockets selected (each once).

import "core:testing"
import "gt:ui"

// A Shift range over two background processes, then Ctrl+Shift adds a third: End task chooses the three, named by
// their count; a new sample that adds a process keeps the selection on its processes.
@(test)
the_acts_take_every_process_selected :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer catalog_destroy(&app.catalog)
	defer table_destroy(&app.table)
	defer delete(app.sampler.procs)
	defer ui.vlist_destroy(&app.vl)
	app.vl.multi = true
	append(&app.sampler.procs,
		Proc{pid = 20, ppid = 1, entry = -1, name = "a", search = "a", start = 1},
		Proc{pid = 21, ppid = 1, entry = -1, name = "b", search = "b", start = 1},
		Proc{pid = 22, ppid = 1, entry = -1, name = "c", search = "c", start = 1},
		Proc{pid = 23, ppid = 1, entry = -1, name = "d", search = "d", start = 1})
	table_columns_init(&app.table)
	table_group(&app.table, app.sampler.procs[:])
	table_rows(&app.table, &app.sampler, &app.catalog)
	// (the process rows in the order shown: the background section's four, one after the other)
	at := make([dynamic]int, context.temp_allocator)
	for r, i in app.table.rows { if r.kind == .Process { append(&at, i) } }
	if !testing.expect_value(t, len(at), 4) { return }
	pid_at :: proc(app: ^App, row: int) -> i32 { return app.sampler.procs[app.table.rows[row].index].pid }
	want := [3]i32{pid_at(app, at[0]), pid_at(app, at[1]), pid_at(app, at[3])}
	holds :: proc(c: Chosen, want: [3]i32) -> bool {
		if len(c.targets) != len(want) { return false }
		for w in want {
			found := false
			for x in c.targets { if x.pid == w { found = true } }
			if !found { return false }
		}
		return true
	}

	// the first two by a Shift range, a move alone takes the cursor's row alone
	select_row(app, at[0])
	ui.item_selection_move(&app.vl.selection, process_rows(app), at[1], {.Shift})
	testing.expect_value(t, len(app.vl.selected), 2)
	ui.item_selection_move(&app.vl.selection, process_rows(app), at[3], {})
	testing.expect_value(t, len(app.vl.selected), 1)
	// again, and the fourth added by Ctrl
	select_row(app, at[0])
	ui.item_selection_move(&app.vl.selection, process_rows(app), at[1], {.Shift})
	ui.item_selection_click(&app.vl.selection, process_rows(app), at[3], {.Ctrl})
	testing.expect_value(t, len(app.vl.selected), 3)

	c, ok := chosen_of_selection(app, whole = false)
	defer chosen_free(&c)
	testing.expect(t, ok && holds(c, want), "the three selected chosen")
	testing.expect_value(t, c.name, "3 processes")

	// a sample with one more process: the rows again, the same three chosen, the cursor on the last clicked
	append(&app.sampler.procs, Proc{pid = 19, ppid = 1, entry = -1, name = "e", search = "e", start = 1})
	table_group(&app.table, app.sampler.procs[:])
	rows_again(app)
	again, ok2 := chosen_of_selection(app, whole = false)
	defer chosen_free(&again)
	testing.expect(t, ok2 && holds(again, want), "the same three after a sample")
	if r, has := selected_row(app); testing.expect(t, has, "a cursor") {
		testing.expect_value(t, app.sampler.procs[r.index].pid, want[2])
	}
}
