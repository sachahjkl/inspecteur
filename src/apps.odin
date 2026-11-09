package inspecteur

// Which processes are apps. Wayland does not let a program see the other programs' windows, so an app is what the
// desktop's menu knows: a desktop entry (XDG: applications/*.desktop under each data folder) whose program, id or
// window class names the process. A process matches by its own name or executable first, then by the systemd unit its
// launcher made for it (app-<launcher>-<desktop id>-<random>.scope). Its children belong to the same app (processes.odin).
//
// The app's icon is the entry's: a PNG of the hicolor theme (or of pixmaps), drawn from a texture made the first time
// it is shown. An SVG-only icon gets the generic one: the toolkit has no SVG rasterizer.

import "core:os"
import "core:strings"
import desktop "gt:desktop"
import "gt:png"
import "gt:render"

App_Entry :: struct {
	id:   string,   // the desktop file's name without .desktop (org.chromium.Chromium)
	name: string,   // Name=
	icon: string,   // Icon=
}

Catalog :: struct {
	entries: [dynamic]App_Entry,   // all strings owned
	keys:    map[string]int,       // a lower-case name -> entry; keys owned
	dirs:    [dynamic]string,      // the data folders, the user's first (owned)
}

// The icon sizes looked for, best first (a row's icon is about 16 to 24 pixels: mipmaps take the larger ones down).
@(private = "file") ICON_SIZES :: [?]string{"32x32", "48x48", "64x64", "24x24", "128x128", "256x256", "22x22", "16x16"}

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
	// a desktop file id names one entry: the first folder's (the user's) wins
	if key_of(id) in c.keys { return }
	at := len(c.entries)
	append(&c.entries, App_Entry{id = strings.clone(id), name = strings.clone(desktop.unescape_value(name)), icon = strings.clone(value(text, "Icon"))})
	add :: proc(c: ^Catalog, key: string, at: int) {
		k := unwrapped(key_of(key))
		if k == "" || k in c.keys { return }
		c.keys[strings.clone(k)] = at
	}
	add(c, id, at)
	// (the last part of a reverse-domain id: org.chromium.Chromium is also chromium)
	if i := strings.last_index_byte(id, '.'); i >= 0 { add(c, id[i + 1:], at) }
	program := desktop.exec_program(value(text, "Exec"))
	if i := strings.last_index_byte(program, '/'); i >= 0 { program = program[i + 1:] }
	// (a launcher that runs another program says nothing of the process: env, flatpak, sh)
	if program != "env" && program != "flatpak" && program != "sh" && program != "bash" { add(c, program, at) }
	add(c, value(text, "StartupWMClass"), at)
}

catalog_destroy :: proc(c: ^Catalog) {
	for e in c.entries { delete(e.id); delete(e.name); delete(e.icon) }
	delete(c.entries)
	for k in c.keys { delete(k) }
	delete(c.keys)
	for d in c.dirs { delete(d) }
	delete(c.dirs)
}

// The entry of a process: its name, its executable's name, then its systemd unit. -1: none.
catalog_match :: proc(c: ^Catalog, name, exe, scope: string) -> int {
	lookup :: proc(c: ^Catalog, key: string) -> int {
		if key == "" { return -1 }
		if at, ok := c.keys[unwrapped(key_of(key))]; ok { return at }
		return -1
	}
	if at := lookup(c, name); at >= 0 { return at }
	base := exe
	if i := strings.last_index_byte(base, '/'); i >= 0 { base = base[i + 1:] }
	if at := lookup(c, base); at >= 0 { return at }
	return scope_match(c, scope)
}

// "app-org.chromium.Chromium-56418.scope", "app-ShojiWM-ghostty-d5e1a437.scope", "app-com.mitchellh.ghostty.service":
// the whole name between "app-" and the unit's type, then each of its parts apart by '-'.
@(private = "file")
scope_match :: proc(c: ^Catalog, scope: string) -> int {
	if !strings.has_prefix(scope, "app-") { return -1 }
	s := scope[4:]
	if i := strings.last_index_byte(s, '.'); i >= 0 && (strings.has_suffix(s, ".scope") || strings.has_suffix(s, ".service")) { s = s[:i] }
	if i := strings.index_byte(s, '@'); i >= 0 { s = s[:i] }
	s, _ = strings.replace_all(s, "\\x2d", "-", context.temp_allocator)
	if at, ok := c.keys[key_of(s)]; ok { return at }
	// (the parts: launcher, id, random; the id may hold dots, never a '-' that systemd did not escape)
	for part in strings.split(s, "-", context.temp_allocator) {
		if at, ok := c.keys[key_of(part)]; ok { return at }
	}
	return -1
}

////////////////////////////////
// Icons

Icon :: struct { tex: render.Texture, ok: bool }

// The texture of an entry's icon, made the first time it is asked; ok false when the icon is not a PNG that can be
// found (the row draws the generic icon).
icon_of :: proc(c: ^Catalog, icons: ^map[string]Icon, r: ^render.Renderer, name: string) -> Icon {
	if name == "" { return {} }
	if ic, done := icons[name]; done { return ic }
	ic: Icon
	if path := icon_path(c, name); path != "" {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
			if rgba, w, h, ok := png.decode(data, context.temp_allocator); ok {
				ic.tex = render.create_texture_rgba(r, w, h)
				render.update_texture_rgba(r, ic.tex, 0, 0, w, h, rgba)
				ic.ok = true
			}
		}
	}
	icons[strings.clone(name)] = ic
	return ic
}

icons_destroy :: proc(icons: ^map[string]Icon, r: ^render.Renderer) {
	for name, ic in icons {
		if ic.ok { render.destroy_texture(r, ic.tex) }
		delete(name)
	}
	delete(icons^)
}

// The PNG of an icon name: an absolute path, else the hicolor theme of each data folder at the sizes of ICON_SIZES,
// else pixmaps. "" when there is none.
@(private = "file")
icon_path :: proc(c: ^Catalog, name: string) -> string {
	if strings.has_prefix(name, "/") { return strings.has_suffix(name, ".png") && os.exists(name) ? name : "" }
	file := strings.concatenate({name, ".png"}, context.temp_allocator)
	sizes := ICON_SIZES
	for size in sizes {
		for d in c.dirs {
			p := strings.concatenate({d, "/icons/hicolor/", size, "/apps/", file}, context.temp_allocator)
			if os.exists(p) { return p }
		}
	}
	for d in c.dirs {
		p := strings.concatenate({d, "/pixmaps/", file}, context.temp_allocator)
		if os.exists(p) { return p }
	}
	return ""
}
