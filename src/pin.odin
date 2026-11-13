package inspecteur

// Pinned apps and processes: kept in a section of their own above the others, whatever the sort (processes.table_rows).
// A row is pinned by its name: an app's (its desktop entry's), a process's (its command's), so a program pinned once
// stays pinned when it starts again. processes.pinned keeps the names.

import "core:strings"
import i18n "gt:i18n"

// The name a selected row is pinned by: its app's for a group and for a process of one (the Pinned section holds what
// the others list at their top: apps and background processes; a process's name pinned inside a group showed nowhere),
// its process's otherwise ("" for none).
pin_name :: proc(app: ^App) -> string {
	r, ok := selected_row(app)
	if !ok { return "" }
	t := &app.table
	switch r.kind {
	case .App:     return app.catalog.entries[t.groups[r.index].entry].name
	case .Process:
		if int(r.index) < len(t.owner) {
			if o := t.owner[r.index]; o >= 0 { return app.catalog.entries[app.sampler.procs[o].entry].name }
		}
		return app.sampler.procs[r.index].name
	case .Section:
	}
	return ""
}

// The pinned names from the preference (each its own copy, the map's keys).
pins_load :: proc(t: ^Table, list: string) {
	pins_clear(t)
	rest := list
	for name in strings.split_iterator(&rest, ",") {
		n := strings.trim_space(name)
		if n != "" && !(n in t.pinned) { t.pinned[strings.clone(n)] = true }
	}
}

pins_clear :: proc(t: ^Table) {
	for name in t.pinned { delete(name) }
	clear(&t.pinned)
}

// Pins the selected row, or unpins it; kept in processes.pinned.
pin_switch :: proc(app: ^App) {
	name := pin_name(app)
	if name == "" { return }
	t := &app.table
	pinned := !t.pinned[name]
	if pinned {
		t.pinned[strings.clone(name)] = true
	} else if name in t.pinned {
		key, _ := delete_key(&t.pinned, name)
		delete(key)
	}
	names := make([dynamic]string, context.temp_allocator)
	for n in t.pinned { append(&names, n) }
	pref_set(&app.prefs, "processes.pinned", strings.join(names[:], ",", context.temp_allocator))
	rows_again(app)
	say(app, pinned ? i18n.tr("%s is pinned over the others") : i18n.tr("%s is unpinned"), name)
}
