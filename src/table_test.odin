package inspecteur

import "core:strings"
import "core:testing"

// The table's rows: the filter (a name, a pid's start), the sort (a group by its sums: its private memory).
@(test)
rows_are_filtered_and_sorted :: proc(t: ^testing.T) {
	c: Catalog
	defer catalog_destroy(&c)
	catalog_add_entry(&c, "editor", "Editor", "", "editor", "")
	procs := []Proc{
		{pid = 10, ppid = 1, entry = 0, name = "editor", search = "editor", private = 100, cpu = 1},
		{pid = 11, ppid = 10, entry = -1, name = "helper", search = "helper", private = 900, cpu = 2},
		{pid = 20, ppid = 1, entry = -1, name = "daemon", search = "daemon --x", private = 500, cpu = 9},
		{pid = 21, ppid = 1, entry = -1, name = "cron", search = "cron", private = 50, cpu = 0},
	}
	s := Sampler{procs = make([dynamic]Proc, context.temp_allocator)}
	append(&s.procs, ..procs)
	tb: Table
	defer table_destroy(&tb)
	table_columns_init(&tb)
	table_group(&tb, s.procs[:])
	testing.expect_value(t, tb.groups[0].private, u64(1000))   // the group's private memory: its two processes'

	// by memory, the largest first: the group, then the background by their own
	tb.layout.sort, tb.layout.descending = int(Column.Memory), true
	table_rows(&tb, &s, &c)
	kinds := make([dynamic]Row_Kind, context.temp_allocator)
	pids := make([dynamic]i32, context.temp_allocator)
	for r in tb.rows {
		append(&kinds, r.kind)
		if r.kind == .Process { append(&pids, s.procs[r.index].pid) }
	}
	testing.expect_value(t, len(tb.rows), 5)   // Apps, the group (closed: helper is in it), Background, two processes
	testing.expect_value(t, kinds[1], Row_Kind.App)
	testing.expect(t, len(pids) == 2 && pids[0] == 20 && pids[1] == 21, "the background by memory: 20, 21")
	// the group open: its processes under it, by memory too
	tb.expanded[tb.groups[0].key] = true
	table_rows(&tb, &s, &c)
	testing.expect_value(t, len(tb.rows), 7)
	testing.expect_value(t, s.procs[tb.rows[2].index].pid, i32(11))
	testing.expect_value(t, s.procs[tb.rows[3].index].pid, i32(10))
	delete_key(&tb.expanded, tb.groups[0].key)

	// the filter: a name finds a group's process (the group opens), a pid's first digits find a process
	tb.query = "help"
	table_rows(&tb, &s, &c)
	testing.expect_value(t, tb.shown_apps, 1)
	testing.expect_value(t, tb.shown_background, 0)
	testing.expect_value(t, len(tb.rows), 3)   // Apps, the group, helper under it
	tb.query = "2"
	table_rows(&tb, &s, &c)
	testing.expect_value(t, tb.shown_apps, 0)
	testing.expect_value(t, tb.shown_background, 2)   // 20 and 21
	tb.query = ""
}

// The columns' layout, written as the preferences keep it and read again, is the same.
@(test)
the_columns_are_kept :: proc(t: ^testing.T) {
	tb: Table
	defer table_destroy(&tb)
	table_layout_load(&tb, Settings{columns = "pid,cpu,resident", widths = "pid=8,command=30", sort = "cpu", descending = true})
	testing.expect(t, tb.layout.shown[int(Column.Resident)] && !tb.layout.shown[int(Column.User)], "the columns asked for")
	testing.expect_value(t, tb.layout.width[int(Column.PID)], 8)
	v := table_layout_values(&tb)
	testing.expect_value(t, v.columns, "pid,cpu,resident")
	testing.expect_value(t, v.widths, "pid=8.0,command=30.0")
	testing.expect_value(t, v.sort, "cpu")
	testing.expect(t, v.descending)
	// a sort by a column not shown goes by name
	tb2: Table
	defer table_destroy(&tb2)
	table_layout_load(&tb2, Settings{columns = "pid", sort = "cpu"})
	c, sorted := table_sort(&tb2)
	testing.expect(t, sorted && c == .Name, "by name")
	// unsorted, and the columns' order, kept
	tb3: Table
	defer table_destroy(&tb3)
	table_layout_load(&tb3, Settings{columns = "pid,cpu,user", order = "cpu,user,pid", sort = "none"})
	_, sorted = table_sort(&tb3)
	testing.expect(t, !sorted, "unsorted")
	v3 := table_layout_values(&tb3)
	testing.expect_value(t, v3.sort, "none")
	// (the columns named take the places they held, in the text's order: cpu, user, pid from left to right)
	cpu, user, pid := strings.index(v3.order, ",cpu,"), strings.index(v3.order, ",user,"), strings.index(v3.order, ",pid,")
	testing.expect(t, strings.has_prefix(v3.order, "name,") && 0 < cpu && cpu < user && user < pid, v3.order)
}

@(test)
priorities_step :: proc(t: ^testing.T) {
	testing.expect_value(t, priority_index(0), 2)
	testing.expect_value(t, priority_index(3), 2)
	testing.expect_value(t, priority_index(-20), 0)
	i, ok := priority_next(0, 1)
	testing.expect(t, ok && PRIORITIES[i].nice == 5, "down from 0: 5")
	i, ok = priority_next(3, -1)
	testing.expect(t, ok && PRIORITIES[i].nice == 0, "up from 3: 0")
	i, ok = priority_next(-15, 1)
	testing.expect(t, ok && PRIORITIES[i].nice == -10, "down from -15: -10")
	_, ok = priority_next(-15, -1)
	testing.expect(t, !ok, "nothing higher than -15 is offered")
	_, ok = priority_next(19, 1)
	testing.expect(t, !ok, "nothing lower than 19")
}

// No two commands that can act in the same place have the same key: the window's with a section's, or two of a section,
// or two of the Properties.
@(test)
no_key_does_two_things :: proc(t: ^testing.T) {
	place :: proc(c: Cmd) -> int {
		if cmd_is_props(c) { return -2 }
		if tab, ok := cmd_tab(c).?; ok { return int(tab) }
		return -1
	}
	for a in Cmd {
		testing.expectf(t, COMMANDS[a].label != "" && COMMANDS[a].group != "", "%v has a label and a group", a)
		for b in Cmd {
			if a >= b { continue }
			pa, pb := place(a), place(b)
			if pa != pb && pa != -1 && pb != -1 { continue }   // (two sections, or a section and the dialog)
			if (pa == -2) != (pb == -2) { continue }           // (the dialog takes the keys while it is open)
			for ka in COMMANDS[a].keys {
				for kb in COMMANDS[b].keys {
					if ka.key != .None && ka == kb { testing.expectf(t, false, "%v and %v share %v", a, b, ka) }
				}
			}
		}
	}
}
