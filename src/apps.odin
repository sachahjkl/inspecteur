package inspecteur

// Which processes are apps. Wayland does not let a program see the other programs' windows, so an app is what the
// desktop's menu knows: an entry of the catalog (apps_linux.odin reads the XDG desktop entries) whose program, id or
// window class names the process. A process matches by its own name or executable first, then by the unit its launcher
// made for it (Linux: the systemd scope app-<launcher>-<desktop id>-<random>.scope). Its children belong to the same app
// (processes.odin).
//
// The app's icon is the entry's, from the person's icon theme (the toolkit's desktop.theme_icon: the theme, what it
// inherits, hicolor, pixmaps; PNG or SVG), drawn from a texture made the first time it is shown.

import "core:strings"
import desktop "gt:desktop"
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

// Adds an entry and the names that lead to it: its id, the last part of a reverse-domain id, its program, its window class.
catalog_add_entry :: proc(c: ^Catalog, id, name, icon, program, window_class: string) {
	// a desktop file id names one entry: the first folder's (the user's) wins
	if key_of(id) in c.keys { return }
	at := len(c.entries)
	append(&c.entries, App_Entry{id = strings.clone(id), name = strings.clone(name), icon = strings.clone(icon)})
	add :: proc(c: ^Catalog, key: string, at: int) {
		k := unwrapped(key_of(key))
		if k == "" || k in c.keys { return }
		c.keys[strings.clone(k)] = at
	}
	add(c, id, at)
	// (the last part of a reverse-domain id: org.chromium.Chromium is also chromium)
	if i := strings.last_index_byte(id, '.'); i >= 0 { add(c, id[i + 1:], at) }
	base := program
	if i := strings.last_index_byte(base, '/'); i >= 0 { base = base[i + 1:] }
	// (a launcher that runs another program says nothing of the process: env, flatpak, sh)
	if base != "env" && base != "flatpak" && base != "sh" && base != "bash" { add(c, base, at) }
	add(c, window_class, at)
}

// A name without a Nix wrapper's marks: ".firefox-wrapped" (or its cut ".firefox-wrappe") is "firefox".
unwrapped :: proc(name: string) -> string {
	n := name
	if strings.has_prefix(n, ".") && strings.contains(n, "-wrap") {
		n = n[1:]
		if i := strings.last_index(n, "-wrap"); i > 0 { n = n[:i] }
	}
	return n
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
scope_match :: proc(c: ^Catalog, scope: string) -> int {
	if !strings.has_prefix(scope, "app-") { return -1 }
	s := scope[4:]
	if i := strings.last_index_byte(s, '.'); i >= 0 && (strings.has_suffix(s, ".scope") || strings.has_suffix(s, ".service")) { s = s[:i] }
	if i := strings.index_byte(s, '@'); i >= 0 { s = s[:i] }
	unescape :: proc(s: string) -> string { out, _ := strings.replace_all(s, "\\x2d", "-", context.temp_allocator); return out }
	if at, ok := c.keys[key_of(unescape(s))]; ok { return at }
	// (the parts: launcher, id, random, apart by '-'; a '-' of the id itself is escaped, \x2d: split first, then
	// unescape each part)
	for part in strings.split(s, "-", context.temp_allocator) {
		if at, ok := c.keys[key_of(unescape(part))]; ok { return at }
	}
	return -1
}

////////////////////////////////
// Icons

Icon :: struct { tex: render.Texture, ok: bool }

// The pixels an app's icon is asked at: a row's icon is about 16 to 24 pixels; mipmaps take the larger one down.
ICON_PX :: 32

// The texture of an app's icon (a desktop entry's Icon=: a name in the person's icon theme, or a file), made the first
// time it is asked; ok false when there is none (the row draws the generic icon).
icon_of :: proc(app: ^App, name: string) -> Icon {
	if name == "" { return {} }
	if ic, done := app.app_icons[name]; done { return ic }
	ic: Icon
	if pic, ok := desktop.theme_icon(name, ICON_PX, context.temp_allocator); ok {
		ic.tex = render.create_texture_rgba(&app.shared.r, pic.size.x, pic.size.y)
		render.update_texture_rgba(&app.shared.r, ic.tex, 0, 0, pic.size.x, pic.size.y, pic.rgba)
		ic.ok = true
	}
	app.app_icons[strings.clone(name)] = ic
	return ic
}

icons_destroy :: proc(icons: ^map[string]Icon, r: ^render.Renderer) {
	for name, ic in icons {
		if ic.ok { render.destroy_texture(r, ic.tex) }
		delete(name)
	}
	delete(icons^)
}
