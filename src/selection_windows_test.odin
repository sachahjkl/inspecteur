#+build windows
package inspecteur

// Windows SCM service action availability checks (including PPL protection refusal).

import "core:testing"
import "gt:ui"

@(test)
win_protected_service_disables_control_commands :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	s := &app.services
	section_table_init(&s.rows, app, WIN_SERVICE_COLUMNS[:])
	defer section_table_destroy(&s.rows)

	list := new(Win_Service_List)
	defer free(list)
	defer delete(list.units)
	append(&list.units,
		Win_Service{name = "WinDefend", state = .Running, startup_type = .Automatic, protection = 3, can_stop = true},
		Win_Service{name = "Spooler", state = .Running, startup_type = .Automatic, protection = 0, can_stop = true, can_pause = true},
	)
	s.list = list
	defer s.list = nil

	section_rows_reset(&s.rows, len(WIN_SERVICE_COLUMNS))
	for u in list.units {
		section_row(&s.rows, name_id(u.name), u.name)
		for _ in WIN_SERVICE_COLUMNS { ui.table_data_cell(&s.rows.data, u.name) }
	}
	ui.table_apply(&s.rows.table, &s.rows.data, "")

	// (by its name: the table sorts its rows, Spooler before WinDefend)
	choose :: proc(t: ^testing.T, app: ^App, name: string) {
		testing.expectf(t, ui.table_select_id(&app.services.rows.table, name_id(name)), "%s is a row", name)
		u, ok := selected_service(app)
		testing.expectf(t, ok && u.name == name, "selected: %q, wanted %q", u.name, name)
	}
	choose(t, app, "WinDefend")
	testing.expect(t, !service_can(app, .Service_Stop), "protected service cannot be stopped")
	testing.expect(t, !service_can(app, .Service_Startup_Type), "protected service startup type cannot be changed")
	testing.expect(t, service_can(app, .Service_Copy), "protected service name can still be copied")

	choose(t, app, "Spooler")
	testing.expect(t, service_can(app, .Service_Stop), "unprotected running service can be stopped")
	testing.expect(t, service_can(app, .Service_Pause), "pausable running service can be paused")
	testing.expect(t, !service_can(app, .Service_Continue), "running service cannot be continued")
}
