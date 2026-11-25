#+build !windows
package inspecteur

// Window enumeration and activation on Linux and macOS (gt:platform toplevels).

import "core:strings"
import i18n "gt:i18n"
import "gt:platform"

Reading_Windows :: struct {}

reading_windows_read :: proc(w: ^Reading_Windows, demo: bool) {}
reading_windows_free :: proc(w: ^Reading_Windows) {}

app_windows_apply :: proc(app: ^App, _: ^Reading_Windows) {
	app_windows_read(app)
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

// Shows a window of the entry: the one that has not the focus (the next of them, when one has it). False: none.
// Shows a window of the entry: the one that has not the focus (the next of them, when one has it). False: none.
window_show :: proc(app: ^App, entry: int) -> bool {
	list := windows_of(app, entry)
	if len(list) == 0 { return false }
	pick := list[0]
	for w, i in list {
		if w.active { pick = list[(i + 1) % len(list)]; break }
	}
	if app.demo != nil {
		say(app, i18n.tr("The window of %s comes to the front"), pick.title)
		return true
	}
	if !platform.toplevel_activate(app.main.win, pick.id) { say(app, i18n.tr("That window has closed")); return false }
	return true
}
