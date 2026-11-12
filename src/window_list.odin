package inspecteur

// The apps' windows: the session's windows as the system tells them (gt:platform toplevels: Wayland's
// wlr-foreign-toplevel, where the compositor offers it), each by its app's desktop entry, matched by its app id as the
// processes are (catalog_match). A row of an app, or of a process of one, has a button that shows its window (Show its
// window): the compositor brings it to the front. Read again at each sample; the demo's are made up.

import "core:fmt"
import "core:strings"
import "gt:platform"

App_Window :: struct {
	entry:  int,      // its app's desktop entry
	id:     u64,      // the system's (platform.toplevel_activate); 0: the demo's
	title:  string,   // owned
	active: bool,
}

// The windows again (each sample).
app_windows_read :: proc(app: ^App) {
	app_windows_clear(app)
	if app.demo != nil {
		// (the demo's apps have their windows: the first ones of its catalog, by their names)
		for e, i in app.catalog.entries[:min(len(app.catalog.entries), DEMO_WINDOWS)] {
			append(&app.windows, App_Window{entry = i, title = strings.clone(e.name), active = i == 0})
		}
		return
	}
	for t in platform.toplevels(app.main.win, context.temp_allocator) {
		e := catalog_match(&app.catalog, t.app_id, "", "")
		if e < 0 { continue }
		append(&app.windows, App_Window{entry = e, id = t.id, title = strings.clone(t.title), active = t.active})
	}
}

app_windows_clear :: proc(app: ^App) {
	for w in app.windows { delete(w.title) }
	clear(&app.windows)
}

// How many windows of the demo's apps (the first entries of its catalog).
@(private = "file") DEMO_WINDOWS :: 4

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

// Shows a window of the entry: the one that has not the focus (the next of them, when one has it). False: none.
window_show :: proc(app: ^App, entry: int) -> bool {
	list := windows_of(app, entry)
	if len(list) == 0 { return false }
	pick := list[0]
	for w, i in list {
		if w.active { pick = list[(i + 1) % len(list)]; break }
	}
	if app.demo != nil {
		say(app, "The window of %s comes to the front", pick.title)
		return true
	}
	if !platform.toplevel_activate(app.main.win, pick.id) { say(app, "That window has closed"); return false }
	return true
}

// The tooltip of a row's window button: the window it shows, or how many there are.
window_tip :: proc(list: []App_Window) -> string {
	if len(list) == 1 { return fmt.tprintf("Show its window: %s", list[0].title) }
	return fmt.tprintf("Show its windows (%d), one after the other", len(list))
}
