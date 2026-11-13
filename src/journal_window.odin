package inspecteur

// A service's journal in a window of its own (Ctrl+Shift+J, or the pane's button): for a second screen, or to keep one
// in view while the window goes elsewhere. The same program, the same renderer: the window is another host.Host on the
// main window's Shared, with a ui.State of its own, built after the main one in its turn of the loop. It has its own
// Journal_View, for the service it was opened for (the pane goes on following the selection); the level, the boot and
// following are the preferences', as in the pane. Its keys are the journal's (Ctrl+J, Alt+L, Alt+B, Alt+F, Alt+C,
// Alt+Shift+C); Ctrl+W closes it. Several can be open, one per service.

import "core:fmt"
import "core:strings"
import "core:time"
import "gt:host"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"

Journal_Window :: struct {
	using window: host.Host,
	app:     ^App,
	view:    Journal_View,
	manager: Manager,
	name:    string,   // owned: the service
}

// Its size at first, in logical pixels.
@(private = "file") JOURNAL_WINDOW_SIZE :: [2]int{960, 620}

// Opens the journal of the service `name` of `manager` in a window of its own (one already open comes forward).
journal_window_open :: proc(app: ^App, manager: Manager, name: string) {
	for w in app.journal_windows {
		if w.manager == manager && w.name == name {
			platform.raise_window(w.win)
			return
		}
	}
	w := new(Journal_Window)
	w.app, w.manager, w.name = app, manager, strings.clone(name)
	if !host.host_open(&w.window, &app.shared, {title = fmt.tprintf("%s: journal", name), size = JOURNAL_WINDOW_SIZE, integrated_title = true}, journal_window_build, w) {
		delete(w.name)
		free(w)
		say(app, "No window for the journal: the renderer refused it")
		return
	}
	w.params = proc(h: ^host.Host, bp: ^ui.Build_Params) { window_params(h, bp, (^Journal_Window)(h.user).app) }
	w.state.icon_font = app.icons
	w.after_input = FRAMES_AFTER_INPUT
	w.partial_redraw = true
	ui.set_rounding(&w.state, ROUNDING)
	platform.set_dark_title(w.win, !app.theme_shown.light)
	// (its readings are posted to its own window: its build takes them)
	journal_view_init(&w.view, app.demo, &w.state)
	journal_view_ask(&w.view, manager, name, app.settings.journal_boot)
	w.view.next = time.tick_add(time.tick_now(), JOURNAL_FOLLOW_MS * time.Millisecond)
	append(&app.journal_windows, w)
	platform.show_window(w.win)
	say(app, "The journal of %s in its own window", name)
}

@(private = "file")
journal_window_build :: proc(h: ^host.Host, size: host.Vec2) {
	w := (^Journal_Window)(h.user)
	app := w.app
	em := ui.font_size()
	journal_window_keys(w)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.Draw_Background}, "###page")
	if ui.parent(page) {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * TITLE_EM)), bg = surface("bar")})
		if ui.title_bar("###titlebar", {.Draw_Background, .Draw_Side_Bottom}) {
			ui.spacer(ui.px(em * 0.6))
			ui.icon(lucide.SCROLL_TEXT, em * 1.4, ui.color("accent"))
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.text_size(em * 0.4), height = ui.pct(1)})
			ui.label(fmt.tprintf("%s###jw_title", ui.text_shown(w.name)))
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###jw_info", journal_window_info(app, w)))
			}
			ui.spacer(ui.px(em * 0.4))
			_, _ = ui.window_buttons()
		}
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = surface("well")})
		body := ui.build_box({.Clip, .Draw_Background}, "###jw_body")
		if ui.parent(body) { journal_build(app, &w.view, w.name, w.manager, true, em, in_window = true) }
		// (what the window's commands said: the main window's footer is elsewhere)
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * FOOTER_EM)), bg = surface("bar")})
		if ui.row(.Center, {.Draw_Background, .Draw_Side_Top}, "###jw_footer") {
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") {
				msg := ui.now_ms() < app.status_until ? app.status : ""
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = em * 0.92})
				ui.label(fmt.tprintf("%s###jw_msg", ui.text_shown(msg)))
			}
		}
	}
	if app.settings.journal_follow && !app.paused { ui.wake_within(&h.state, max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), w.view.next))) + 1, 1)) }
}

// "system service · since …": its manager, and what its reading says.
@(private = "file")
journal_window_info :: proc(app: ^App, w: ^Journal_Window) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, w.manager == .System ? "a system service" : "a user service")
	if d := w.view.details; d != nil && d.name == w.name {
		if d.since > 0 { append(&parts, fmt.tprintf("in its state since %s", started_text(app, d.since))) }
		if d.file != "" { append(&parts, d.file) }
	}
	return strings.join(parts[:], "  ·  ", context.temp_allocator)
}

// The journal's keys in its window; Ctrl+W closes it.
@(private = "file")
journal_window_keys :: proc(w: ^Journal_Window) {
	app := w.app
	if journal_search_escape(&w.view) { return }
	if ui.key_press(.W, {.Ctrl}) { platform.request_close(w.win); return }
	field := w.view.search_key != 0 && ui.focus_key() == w.view.search_key
	for c in ([?]Cmd{.Journal_Search, .Journal_Level, .Journal_Boot, .Journal_Follow, .Journal_Copy, .Journal_Copy_Entry}) {
		cmd := COMMANDS[c]
		// (the search keeps its editing keys: Alt+C is no editing key, Ctrl+J gives it the keyboard again)
		if field && c == .Journal_Search { continue }
		if ui.command_pressed(cmd, journal_can_on(app, &w.view, c)) { journal_run_on(app, &w.view, c) }
	}
}

// The loop's wait: the main window and the journals' (a journal's own timers count: following, a tooltip).
// The loop's wait: on every window, the main one, the journals' and Mission Control's panels'.
windows_wait :: proc(app: ^App) {
	hosts := make([dynamic]^host.Host, 0, 1 + len(app.journal_windows) + len(app.mission_windows), context.temp_allocator)
	append(&hosts, &app.main)
	for w in app.journal_windows { append(&hosts, &w.window) }
	for w in app.mission_windows { append(&hosts, &w.window) }
	host.hosts_wait(hosts[:])
}

// After the main window's frame: each journal's window followed, built; a closed one goes once its reading is done (the
// reading's job holds its view until then).
journal_windows_frame :: proc(app: ^App) {
	for i := len(app.journal_windows) - 1; i >= 0; i -= 1 {
		w := app.journal_windows[i]
		if platform.is_closed(w.win) {
			ordered_remove(&app.journal_windows, i)
			append(&app.journals_closed, w)
			continue
		}
		if journal_view_taken(&w.view) { w.settle = max(w.settle, 1) }
		if app.settings.journal_follow && !app.paused && time.tick_diff(w.view.next, time.tick_now()) >= 0 && !journal_view_busy(&w.view) {
			w.view.next = time.tick_add(time.tick_now(), JOURNAL_FOLLOW_MS * time.Millisecond)
			journal_view_ask(&w.view, w.manager, w.name, app.settings.journal_boot)
		}
		host.host_frame(&w.window)
	}
	for i := len(app.journals_closed) - 1; i >= 0; i -= 1 {
		w := app.journals_closed[i]
		if journal_view_busy(&w.view) { continue }
		unordered_remove(&app.journals_closed, i)
		journal_window_free(w)
	}
}

// At the end, once the chores stopped: every journal's window closed.
journal_windows_close :: proc(app: ^App) {
	for w in app.journal_windows { journal_window_free(w) }
	for w in app.journals_closed { journal_window_free(w) }
	delete(app.journal_windows)
	delete(app.journals_closed)
}

@(private = "file")
journal_window_free :: proc(w: ^Journal_Window) {
	// (a reading posted and not taken yet: taken now, so that the view frees it)
	ui.drain_posts(&w.state)
	journal_view_destroy(&w.view)
	host.host_close(&w.window)
	delete(w.name)
	free(w)
}
