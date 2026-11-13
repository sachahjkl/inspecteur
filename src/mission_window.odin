package inspecteur

// A panel of Mission Control in a window of its own (its menu's "Open in a window"): for a second screen, or to keep it in
// view while the main window shows another section. The same program, the same renderer: another host.Host on the main
// window's Shared with a ui.State of its own, as a journal's window (journal_window.odin), and it builds the same panel.
// A click on one of its lines shows that section in the main window, which comes forward. Closed (its button, Ctrl+W),
// the panel goes back to Mission Control, beside the others. The windows open are kept (mission.windows) and open again
// at the next start; while one is open, what Mission Control sums up is read as when it is shown.

import "core:fmt"
import "core:strings"
import config "gt:config"
import "gt:host"
import "gt:platform"
import "gt:ui"

Mission_Window :: struct {
	using window: host.Host,
	app:   ^App,
	panel: Mission_Panel,
}

// Its size at first, in logical pixels.
@(private = "file") MISSION_WINDOW_SIZE :: [2]int{720, 480}

// Opens panel `p` in a window of its own (one already open comes forward); the dock has let it go.
mission_window_open :: proc(app: ^App, p: Mission_Panel) {
	for w in app.mission_windows {
		if w.panel == p {
			platform.raise_window(w.win)
			return
		}
	}
	w := new(Mission_Window)
	w.app, w.panel = app, p
	if !host.host_open(&w.window, &app.shared, {title = MISSION_TITLES[p], size = MISSION_WINDOW_SIZE, integrated_title = true}, mission_window_build, w) {
		free(w)
		mission_dock_back(app, p)
		say(app, "No window for %s: the renderer refused it", MISSION_TITLES[p])
		return
	}
	w.params = proc(h: ^host.Host, bp: ^ui.Build_Params) { window_params(h, bp, (^Mission_Window)(h.user).app) }
	w.state.icon_font = app.icons
	w.after_input = FRAMES_AFTER_INPUT
	window_standard(app, &w.window)
	platform.set_dark_title(w.win, !app.theme_shown.light)
	append(&app.mission_windows, w)
	mission_windows_save(app)
	mission_read(app)
	platform.show_window(w.win)
}

@(private = "file")
mission_window_build :: proc(h: ^host.Host, size: host.Vec2) {
	w := (^Mission_Window)(h.user)
	app := w.app
	em := ui.font_size()
	if ui.key_press(.W, {.Ctrl}) { platform.request_close(w.win) }
	tab := app.tab
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.Draw_Background}, "###page")
	if ui.parent(page) {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * TITLE_EM)), bg = surface("bar")})
		if ui.title_bar("###titlebar", {.Draw_Background, .Draw_Side_Bottom}) {
			ui.spacer(ui.px(em * 0.6))
			if app.logo.ok { icon_box(app.logo, em * 1.4) }
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.text_size(em * 0.4), height = ui.pct(1)})
			ui.label(fmt.tprintf("%s###mw_title", MISSION_TITLES[w.panel]))
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label("Mission Control###mw_info")
			}
			ui.spacer(ui.px(em * 0.4))
			_, _ = ui.window_buttons()
		}
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###mw_body") { mission_panel(app, w.panel, em) }
	}
	mission_line_menu(app, em)
	// (a line clicked showed its section in the main window: it comes forward)
	if app.tab != tab { platform.raise_window(app.main.win) }
}

// Each frame of the loop: a panel let go opens in its window; the windows closed give their panel back to the dock; the
// others are built.
mission_windows_frame :: proc(app: ^App) {
	if p, ok := app.mission.to_window.?; ok {
		app.mission.to_window = nil
		mission_window_open(app, p)
	}
	for i := len(app.mission_windows) - 1; i >= 0; i -= 1 {
		w := app.mission_windows[i]
		if platform.is_closed(w.win) {
			ordered_remove(&app.mission_windows, i)
			mission_dock_back(app, w.panel)
			host.host_close(&w.window)
			free(w)
			mission_windows_save(app)
			continue
		}
		host.host_frame(&w.window)
	}
}

// The windows open again, as they were at the last start's end (after the main window is shown).
mission_windows_restore :: proc(app: ^App) {
	names := strings.split(config.string_of(&app.prefs, "mission.windows"), ",", context.temp_allocator)
	for name in names {
		for n, p in MISSION_NAMES {
			// (a panel the layout has again, the layout written by another version: it stays there)
			if n == strings.trim_space(name) && !ui.dock_has(&app.mission.dock, u32(p)) { mission_window_open(app, p) }
		}
	}
}

// At the end: the windows go, their panels stay out of the layout (mission.windows opens them again).
mission_windows_close :: proc(app: ^App) {
	for w in app.mission_windows {
		host.host_close(&w.window)
		free(w)
	}
	delete(app.mission_windows)
}

@(private = "file")
mission_windows_save :: proc(app: ^App) {
	names := make([dynamic]string, context.temp_allocator)
	for w in app.mission_windows { append(&names, MISSION_NAMES[w.panel]) }
	pref_set(&app.prefs, "mission.windows", strings.join(names[:], ",", context.temp_allocator))
}
