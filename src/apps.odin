package inspecteur

// Which processes are apps. Wayland does not let a program see the other programs' windows, so an app is what the
// desktop's menu knows: an entry of the catalog (apps_linux.odin reads the XDG desktop entries) whose program, id or
// window class names the process. A process matches by its own name or executable first, then by the unit its launcher
// made for it (Linux: the systemd scope app-<launcher>-<desktop id>-<random>.scope). Its children belong to the same app
// (processes.odin).
//
// The app's icon is the entry's, from the person's icon theme (the toolkit's desktop.theme_icon: the theme, what it
// inherits, hicolor, pixmaps; PNG or SVG), drawn from a texture made the first time it is shown.

import "core:slice"
import "core:strings"
import desktop "gt:desktop"
import "gt:render"
import identity "identity"

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
	// (`program` is program_of's: never a launcher or an interpreter, whose name every process of theirs has)
	add(c, base_name(program), at)
	add(c, window_class, at)
}

// The programs that start another one (env, sudo, flatpak, systemd-run...): an entry's Exec that begins with one of them
// names its program further on.
LAUNCHERS := [?]string{
	"env", "sudo", "doas", "pkexec", "xdg-open", "gio", "gtk-launch", "systemd-run", "uwsm", "app2unit", "dbus-launch",
	"dbus-run-session", "nix", "nix-shell", "steam-run", "bwrap", "flatpak", "flatpak-spawn", "nice", "ionice", "setsid",
	"firejail", "gamemoderun", "prime-run", "exec",
}
// The words of a launcher that come before the program (`flatpak run`, `gio launch`, `uwsm app`, `nix run`).
LAUNCHER_WORDS := [?]string{"run", "launch", "app", "open", "shell", "exec", "--"}
// A launcher's options that take the next word as their value (`sudo -u alex`, `nice -n 5`, `systemd-run --unit x`; not
// `--user`: systemd-run's takes none).
LAUNCHER_VALUED := [?]string{"-u", "-g", "-n", "-p", "-c", "--unit", "--slice", "--command"}
// The programs that run a script or a program of their own (an interpreter, a runtime, a shell): the program is the
// first argument that is not an option. By name, or by the start of it (python3.12, electron32, wine64, nodejs).
INTERPRETERS := [?]string{"sh", "bash", "dash", "zsh", "fish", "ksh", "mono", "dotnet", "java", "deno", "bun", "lua", "php", "tclsh", "wish", "osascript"}
INTERPRETER_PREFIXES := [?]string{"python", "perl", "ruby", "node", "electron", "wine", "pypy", "luajit"}

is_launcher :: proc(name: string) -> bool {
	for l in LAUNCHERS { if name == l { return true } }
	return false
}

is_interpreter :: proc(name: string) -> bool {
	for i in INTERPRETERS { if name == i { return true } }
	for p in INTERPRETER_PREFIXES { if strings.has_prefix(name, p) { return true } }
	return false
}

// "/usr/bin/firefox" is "firefox"; a Nix wrapper's ".firefox-wrapped" too.
base_name :: proc(path: string) -> string {
	b := path
	if i := strings.last_index_byte(b, '/'); i >= 0 { b = b[i + 1:] }
	return unwrapped(b)
}

// The program a command line runs (its words), by its name: past the launchers (`env FOO=1 sudo -u x prog`), and for an
// interpreter its script or program (`python3 -u /opt/app/main.py` is main.py, `sh -c "prog --x"` is prog, `python -m
// app` is app). "" when there is none: an interpreter alone, a launcher of nothing.
program_of :: proc(args: []string) -> string {
	i := 0
	for i < len(args) {
		base := base_name(args[i])
		switch {
		case is_launcher(base):
			i += 1
			for i < len(args) {
				w := args[i]
				if slice.contains(LAUNCHER_VALUED[:], w) { i += 2; continue }
				if slice.contains(LAUNCHER_WORDS[:], w) || strings.has_prefix(w, "-") || strings.contains(w, "=") || is_number(w) { i += 1; continue }
				break
			}
		case is_interpreter(base):
			i += 1
			for i < len(args) && strings.has_prefix(args[i], "-") {
				if (args[i] == "-c" || args[i] == "-m") && i + 1 < len(args) {
					if args[i] == "-m" { return args[i + 1] }
					return program_of(strings.fields(args[i + 1], context.temp_allocator))
				}
				i += 1
			}
			return i < len(args) ? base_name(args[i]) : ""
		case:
			return base
		}
	}
	return ""
}

@(private = "file")
is_number :: proc(w: string) -> bool {
	if w == "" { return false }
	for c in transmute([]u8)w { if c < '0' || c > '9' { return false } }
	return true
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

// The entry of a process: its name, its executable's name, an interpreter's script (its command line), then its systemd
// unit. -1: none.
catalog_match :: proc(c: ^Catalog, name, exe, scope: string, cmdline := "") -> int {
	lookup :: proc(c: ^Catalog, key: string) -> int {
		if key == "" { return -1 }
		if at, ok := c.keys[unwrapped(key_of(key))]; ok { return at }
		return -1
	}
	if at := lookup(c, name); at >= 0 { return at }
	base := base_name(exe)
	if at := lookup(c, base); at >= 0 { return at }
	if is_interpreter(name) || is_interpreter(base) {
		if at := lookup(c, program_of(strings.fields(cmdline, context.temp_allocator))); at >= 0 { return at }
	}
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

// An app's icon: a texture, or (the demo's) a glyph of Lucide on a tile of its own colour.
Icon :: struct {
	tex:   render.Texture,
	ok:    bool,
	glyph: string,     // not "": the tile's glyph (no texture)
	tint:  [4]f32,     // the tile's colour
}

// The pixels an app's icon is asked at: a row's icon is about 16 to 24 pixels; mipmaps take the larger one down.
ICON_PX :: 32

// The texture of an app's icon (a desktop entry's Icon=: a name in the person's icon theme, or a file), made the first
// time it is asked; ok false when there is none (the row draws the generic icon).
icon_of :: proc(app: ^App, name: string) -> Icon {
	if name == "" { return {} }
	// (Inspecteur's own row: its logo, whatever the icon theme has)
	if name == identity.SLUG && app.logo.ok { return app.logo }
	// (the demo's apps: icons of its own, the same on every machine; no theme is read)
	if app.demo != nil { return demo_icon(name) }
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
