package inspecteur

// The apps on Linux: the XDG desktop entries (applications/*.desktop under $XDG_DATA_HOME and each $XDG_DATA_DIRS) that
// the desktop's menu shows: applications that have a window (not hidden, not run in a terminal).

import "core:os"
import "core:strings"
import desktop "gt:desktop"

catalog_load :: proc(c: ^Catalog) {
	home := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if home == "" { home = strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.local/share"}, context.temp_allocator) }
	append(&c.dirs, strings.clone(home))
	dirs := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if dirs == "" { dirs = "/usr/local/share:/usr/share" }
	for d in strings.split(dirs, ":", context.temp_allocator) {
		if d == "" { continue }
		seen := false
		for e in c.dirs { if e == d { seen = true } }
		if !seen { append(&c.dirs, strings.clone(d)) }
	}
	for d in c.dirs {
		folder := strings.concatenate({d, "/applications"}, context.temp_allocator)
		files, err := os.read_all_directory_by_path(folder, context.temp_allocator)
		if err != nil { continue }
		for f in files {
			if !strings.has_suffix(f.name, ".desktop") { continue }
			data, rerr := os.read_entire_file(f.fullpath, context.temp_allocator)
			if rerr != nil { continue }
			catalog_add(c, strings.trim_suffix(f.name, ".desktop"), string(data))
		}
	}
}

// One desktop entry: an application that has a window (not hidden, not run in a terminal).
catalog_add :: proc(c: ^Catalog, id, text: string) {
	value :: proc(text, key: string) -> string { v, _ := desktop.entry_value(text, key); return v }
	if value(text, "Type") != "Application" || value(text, "NoDisplay") == "true" || value(text, "Hidden") == "true" || value(text, "Terminal") == "true" { return }
	name := value(text, "Name")
	if name == "" { return }
	words := make([dynamic]string, context.temp_allocator)
	for a in desktop.exec_arguments(value(text, "Exec")) { append(&words, a.text) }
	catalog_add_entry(c, id, desktop.unescape_value(name), value(text, "Icon"), program_of(words[:]), value(text, "StartupWMClass"))
}
