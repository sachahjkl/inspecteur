package inspecteur

// One Inspecteur at a time (the toolkit's gt:instance): a second start (Ctrl+Shift+Escape again, the CPU Meter's button,
// the menu's entry) hands its section and its activation token to the one that runs, which shows that section and
// comes to the front; the second start then ends. A copy of another executable (a Nix store's after an update, a build
// beside it) runs on its own. The demo and --first-frame (the tools) are never forwarded.

import "core:fmt"
import "core:strings"
import instance "gt:instance"
import "gt:platform"
import process "gt:process"
import "gt:ui"

// How long a second start waits for the first while it is starting or closing.
@(private = "file") ONE_COPY_WAIT_MS :: 3000

// At a start with the window: hands `tab` (asked: `asked`) to a running Inspecteur. `forwarded`: it took it, this start
// ends; else `owner` is this one's to serve (First), or nothing (another copy, or one that does not answer).
one_copy_acquire :: proc(tab: Tab, asked: bool) -> (forwarded: bool, owner: instance.Owner, owns: bool) {
	token := platform.activation_token_from_env(context.temp_allocator)
	message := fmt.tprintf("%s\n%s", asked ? TAB_LABELS[tab] : "", token)
	cfg := instance.Instance_Options{name = instance.key("inspecteur", platform.user_dir(.Config, "", context.temp_allocator)), identity = process.executable_path(), wait_ms = ONE_COPY_WAIT_MS}
	outcome, o := instance.acquire(cfg, transmute([]byte)message)
	switch outcome {
	case .Forwarded:      return true, {}, false
	case .First:          return false, o, true
	case .Other_Instance, .Unresponsive:
	}
	return false, {}, false
}

// Serves the name once the window is open: a message of a second start is the window's at its next build.
one_copy_serve :: proc(app: ^App, owner: instance.Owner) {
	app.one_copy = instance.serve_start(owner, proc(user: rawptr, message: []byte) {
		app := (^App)(user)
		text := strings.clone(string(message))   // (the call's own: freed by one_copy_show)
		ui.post(&app.main.state, one_copy_show, rawptr(raw_data(text)), u64(len(text)))
	}, app)
}

one_copy_stop :: proc(app: ^App) {
	if app.one_copy != nil { instance.serve_stop(app.one_copy) }
}

// (the interface's thread) The section a second start asked for, the window to the front.
@(private = "file")
one_copy_show :: proc(data: rawptr, word: u64) {
	text := string(([^]u8)(data)[:word])
	defer delete(text)
	app := the_app
	if app == nil { return }
	section, _, token := strings.partition(text, "\n")
	if t, ok := tab_of(section); ok && section != "" {
		app.settings_open = false
		tab_show(app, t)
	}
	platform.raise_window_token(app.main.win, token)
	app.main.settle = max(app.main.settle, FRAMES_AFTER_INPUT)
}
