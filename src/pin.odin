package inspecteur

// Pinned apps and processes: kept in a section of their own above the others, whatever the sort (processes.table_rows).
// A row is pinned by its name: an app's (its desktop entry's), a process's (its command's), so a program pinned once
// stays pinned when it starts again. processes.pinned keeps the names.

import "core:strings"

// The name a selected row is pinned by: its app's for a group, its process's otherwise ("" for none).
pin_name :: proc(app: ^App) -> string {
	r, ok := selected_row(app)
	if !ok { return "" }
	switch r.kind {
	case .App:     return app.catalog.entries[app.table.groups[r.index].entry].name
	case .Process: return app.sampler.procs[r.index].name
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
	pref_save(&app.prefs, "processes.pinned", strings.join(names[:], ",", context.temp_allocator))
	rows_again(app)
	say(app, pinned ? "%s is pinned over the others" : "%s is unpinned", name)
}
