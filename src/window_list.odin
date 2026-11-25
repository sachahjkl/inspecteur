package inspecteur

// The apps' windows: the session's windows as the system tells them, each by its app's entry of the catalog. A row of an
// app, or of a process of one, has a button that shows its window (Show its window): it comes to the front. Read again at
// each sample; the demo's are made up. The system's side is in window_list_other.odin (gt:platform toplevels: Wayland's
// wlr-foreign-toplevel, where the compositor offers it; the app id matched as the processes are, catalog_match) and
// window_list_windows.odin.

import "core:fmt"
import i18n "gt:i18n"

App_Window :: struct {
	entry:  int,      // its app's desktop entry
	id:     u64,      // the system's handle or toplevel id; 0: the demo's
	title:  string,   // owned
	active: bool,
}

// How many windows of the demo's apps (the first entries of its catalog).
DEMO_WINDOWS :: 4

app_windows_clear :: proc(app: ^App) {
	for w in app.windows { delete(w.title) }
	clear(&app.windows)
}

// The windows of the desktop entry `entry` (temp memory); none for -1.
windows_of :: proc(app: ^App, entry: int) -> []App_Window {
	out := make([dynamic]App_Window, context.temp_allocator)
	if entry < 0 { return out[:] }
	for w in app.windows { if w.entry == entry { append(&out, w) } }
	return out[:]
}

// The desktop entry of a row: an app's, or a process's own.
row_entry :: proc(app: ^App, r: Row) -> int {
	#partial switch r.kind {
	case .App:     return app.table.groups[r.index].entry
	case .Process: return app.sampler.procs[r.index].entry
	}
	return -1
}

// The tooltip of a row's window button: the window it shows, or how many there are.
window_tip :: proc(list: []App_Window) -> string {
	if len(list) == 1 { return fmt.tprintf(i18n.tr("Show its window: %s"), list[0].title) }
	return fmt.tprintf(i18n.tr(len(list), "Show its windows (%d), one after the other", "Show its windows (%d), one after the other"), len(list))
}
