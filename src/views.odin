package inspecteur

// The views (gui_toolkit's views, its docs/views.md): Properties, the affinity, "Why is it slow?", the service's details,
// a service's journal and the eight panels of Mission Control. Each is a build procedure on the App, declared once; the
// toolkit builds it where the user puts it (a dialog, a floating window inside the window, a window of its own, a
// panel docked at an edge of the window or of the Services and Mission Control sections) and keeps that choice, the
// sizes, the docks' layouts and which were open at the last quit in <state>/inspecteur/views.txt.
//
// The command palette, the sheet of the keys, the confirmations and the install's dialog are the toolkit's own views,
// on the same Views.

import "core:strings"
import "gt:host"
import "gt:platform"
import "gt:ui"

PROPS_VIEW     :: "props"
AFFINITY_VIEW  :: "affinity"
DIAGNOSIS_VIEW :: "diagnosis"
SERVICE_VIEW   :: "service"
JOURNAL_VIEW   :: "journal"     // an instance per service ("<manager>/<service>")
// The confirmation of a kill, a signal, a service's stop, a dump (the toolkit's ui.confirm_open).
CONFIRM_VIEW   :: "kill"

// The dock spaces of the sections: the Services section's (the table its centre), Mission Control's (panels only).
SERVICES_SPACE :: "services"
MISSION_SPACE  :: "mission"

// Where the views' memory is: none (in memory only) in the demo, whose pictures must not depend on what the user chose.
@(private = "file")
views_file :: proc(app: ^App) -> string {
	if app.demo != nil { return "" }
	return strings.concatenate({platform.user_dir(.State, APP_NAME, context.temp_allocator), "/views.txt"}, context.temp_allocator)
}

// Once the window is open, before its first frame: the memory read (on this thread, once), each view declared, the
// panels open again as they were at the last quit.
views_start :: proc(app: ^App) {
	h := &app.main
	ui.views_init(&app.views, {path = views_file(app)})
	ui.set_views(&h.state, &app.views)
	ui.views_set_windows(&app.views, host.view_windows(h.shared))
	props_register(app)
	affinity_register(app)
	diagnosis_register(app)
	service_register(app)
	journal_register(app)
	mission_register(app)
	// (the details open at the very first start, as they were by default; then as the user left them)
	_ = ui.view_restore(&app.views, SERVICE_VIEW, app, first_start_open = true, owner = &h.state)
	mission_restore(app)
	journals_restore(app)
}

// Whether the keyboard is in one of the views (a floating, docked or separate one), the service's details apart: their
// keys are the Services section's. The section's keys wait then; the window's still act (Ctrl+K from a floating view).
focus_in_view :: proc(app: ^App) -> bool {
	id, _, ok := ui.views_focus(&app.views)
	return ok && id != SERVICE_VIEW
}
