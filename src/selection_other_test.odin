#+build !windows
package inspecteur

import "core:testing"
import "gt:ui"

// Ctrl+A on the services, then Stop: the running ones alone; Start: the others alone; Copy name takes them all.
@(test)
an_action_on_services_takes_those_it_means_something_for :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	s := &app.services
	section_table_init(&s.rows, app, SERVICE_COLUMNS[:])
	defer section_table_destroy(&s.rows)
	list := new(Service_List)
	defer free(list)
	defer delete(list.units)
	append(&list.units,
		Service{name = "a.service", active = "active", sub = "running", load = "loaded", file = "enabled"},
		Service{name = "b.service", active = "inactive", sub = "dead", load = "loaded", file = "disabled"},
		Service{name = "c.service", active = "active", sub = "running", load = "loaded", file = "static"})
	s.list = list
	defer s.list = nil
	section_rows_reset(&s.rows, len(SERVICE_COLUMNS))
	for u in list.units {
		section_row(&s.rows, name_id(u.name), u.name)
		for _ in SERVICE_COLUMNS { ui.table_data_cell(&s.rows.data, u.name) }
	}
	ui.table_apply(&s.rows.table, &s.rows.data, "")
	ui.item_selection_all(&s.rows.table.vl.selection, table_rows_now(&s.rows.table))
	s.rows.table.vl.sel = 0

	names :: proc(units: []Service) -> (out: [3]string, n: int) {
		for u in units { if n < len(out) { out[n] = u.name; n += 1 } }
		return
	}
	stop, n_stop := names(service_targets(app, .Stop))
	testing.expect(t, n_stop == 2 && stop[0] == "a.service" && stop[1] == "c.service", "Stop: the two running")
	start, n_start := names(service_targets(app, .Start))
	testing.expect(t, n_start == 1 && start[0] == "b.service", "Start: the one stopped")
	_, n_enable := names(service_targets(app, .Enable))
	testing.expect_value(t, n_enable, 1)   // (b alone is disabled; a is enabled, c static)
	testing.expect_value(t, len(selected_rows(&s.rows.table)), 3)

	// nothing selected: the cursor's row alone (a row the program chose, before its build)
	ui.item_selection_clear(&s.rows.table.vl.selection)
	stop, n_stop = names(service_targets(app, .Stop))
	testing.expect(t, n_stop == 1 && stop[0] == "a.service", "the cursor's service alone")
}
