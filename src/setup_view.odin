package inspecteur

// The welcome page: at the first start (setup.welcome), and from the palette (Desktop integration…, Ctrl+Shift+I). It
// says what Inspecteur is and its first keys; it puts Inspecteur in the application menu with its icon, or takes it
// away (integration.odin); it says how a desktop opens it as its task manager. Done writes setup.welcome = false.

import "core:fmt"
import "core:strings"
import "gt:draw"
import "gt:platform"
import "gt:render"
import "gt:ui"
import identity "identity"

SETUP_W_EM :: 38
SETUP_LOGO_EM :: 4.5

Setup_Page :: struct {
	open:      bool,
	state:     Integration,   // read when the page opens and after each change
	read:      bool,
	logo:      render.Texture,
	logo_made: bool,
}

setup_destroy :: proc(p: ^Setup_Page) { integration_free(&p.state) }

// At the start: the page, the first time.
setup_offer :: proc(app: ^App) {
	if app.settings.welcome && app.demo == nil { setup_show(app) }
}

setup_show :: proc(app: ^App) {
	p := &app.setup
	p.open = true
	integration_free(&p.state)
	p.state = integration_status()
	p.read = true
}

setup_build :: proc(app: ^App, em: f32) {
	p := &app.setup
	was := p.open
	w := em * SETUP_W_EM
	if ui.modal("setup", w, &p.open) {
		pad := em * 1.4
		ui.next({width = ui.px(w), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###setup") {
			ui.spacer(ui.px(pad))
			ui.next({width = ui.px(w), height = ui.children_sum()})
			if ui.row(.Center, {}, "###setup_head") {
				ui.spacer(ui.px(pad))
				setup_logo(app, em * SETUP_LOGO_EM)
				ui.spacer(ui.px(em))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					ui.next({width = ui.fill(), font_size = em * 1.5})
					ui.paragraph("Welcome to Inspecteur###setup_title")
					if ui.tags("weak") {
						ui.next({width = ui.fill()})
						ui.paragraph("What runs, what it uses, and a way to end it.###setup_sub")
					}
				}
				ui.spacer(ui.px(pad))
			}
			ui.spacer(ui.px(em))
			setup_text(fmt.tprintf("Type anywhere to filter. %s lists every action, %s every key.###setup_keys",
				ui.command_keys_text(COMMANDS[.Palette]), ui.command_shortcut(COMMANDS[.Shortcuts])), w, pad, false)
			ui.spacer(ui.px(em))
			setup_heading("The application menu", w, pad, em)
			st := &p.state
			status: string
			switch {
			case st.nix:       status = "Installed by Nix: the package brings its menu entry and its icon."
			case st.installed: status = fmt.tprintf("In the application menu, with its icon (%s).", st.entry)
			case st.repair:    status = "Partly in the application menu: Add repairs it."
			case:              status = "Not in the application menu yet."
			}
			setup_text(fmt.tprintf("%s###setup_status", status), w, pad, true)
			ui.spacer(ui.px(em * 0.6))
			if !st.nix {
				ui.next({width = ui.px(w), height = ui.children_sum()})
				if ui.row(.Center, {}, "###setup_menu_buttons") {
					ui.spacer(ui.px(pad))
					ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
					if ui.tags("accent_button") {
						if ui.button(st.installed ? "Add again###setup_install" : "Add to the application menu###setup_install").clicked { setup_install(app) }
					}
					if st.installed || st.repair {
						ui.spacer(ui.px(em * 0.6))
						ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
						if ui.button("Remove###setup_remove").clicked { setup_remove(app) }
					}
				}
			}
			ui.spacer(ui.px(em))
			// (the demo's desktop is GNOME's: the pictures say nothing of the machine they are made on)
			hint := task_manager_hint(app.demo != nil ? "GNOME" : current_desktop())
			setup_heading(hint.desktop != "" ? fmt.tprintf("The task manager of %s", hint.desktop) : "The desktop's task manager", w, pad, em)
			setup_text(fmt.tprintf("%s###setup_tm", hint.steps), w, pad, true)
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.px(w), height = ui.children_sum()})
			if ui.row(.Center, {}, "###setup_tm_buttons") {
				ui.spacer(ui.px(pad))
				ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
				if hint.can_bind {
					if ui.button("Add Shortcut###setup_bind").clicked {
						why := app.demo != nil ? DEMO_REFUSED : task_manager_bind()
						if why == "" { say(app, "Ctrl+Shift+Escape opens Inspecteur") } else { say(app, "No shortcut: %s", why) }
					}
				} else if hint.copy != "" {
					if ui.button(fmt.tprintf("%s###setup_copy", hint.copy_label)).clicked {
						platform.set_clipboard(app.main.win, hint.copy)
						say(app, "Copied %s", hint.copy)
					}
				}
			}
			ui.spacer(ui.px(em * 1.2))
			ui.hline(ui.px(w))
			ui.spacer(ui.px(em * 0.7))
			ui.next({width = ui.px(w), height = ui.children_sum()})
			if ui.row(.Center, {}, "###setup_foot") {
				ui.spacer(ui.px(pad))
				if ui.tags("weak") {
					msg := ui.now_ms() < app.status_until ? app.status : ""
					ui.next({width = ui.fill(), height = ui.px(em * 2), font_size = em * 0.9, text_pad = 0})
					label_tip(fmt.tprintf("%s###setup_msg", ui.text_shown(msg)), msg)
				}
				ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
				if ui.button("Done###setup_done").clicked { p.open = false }
				ui.spacer(ui.px(pad))
			}
			ui.spacer(ui.px(em * 0.7))
		}
	}
	// (closed, by Done or Escape: it does not open by itself again)
	if was && !p.open && app.settings.welcome {
		app.settings.welcome = false
		pref_save(&app.prefs, "setup.welcome", "false")
	}
}

@(private = "file")
setup_heading :: proc(text: string, w, pad, em: f32) {
	ui.next({width = ui.px(w), height = ui.px(em * 1.8)})
	if ui.row(.Center, {}, fmt.tprintf("###h_%s", text)) {
		ui.spacer(ui.px(pad))
		ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, fg = ui.color("accent")})
		ui.label(fmt.tprintf("%s###t", text))
	}
}

@(private = "file")
setup_text :: proc(id_text: string, w, pad: f32, weak: bool) {
	ui.next({width = ui.px(w), height = ui.children_sum()})
	if ui.row(.Start, {}, fmt.tprintf("###row_%s", id_text[strings.index(id_text, "###") + 3:])) {
		ui.spacer(ui.px(pad))
		if weak { ui.push_tags("weak") }
		ui.next({width = ui.px(w - 2 * pad)})
		if ui.style({text_pad = 0}) { ui.paragraph(id_text) }
		if weak { ui.pop_tags() }
	}
}

@(private = "file")
setup_install :: proc(app: ^App) {
	if why := integration_install(); why != "" {
		say(app, "Not added: %s", why)
	} else {
		say(app, "Inspecteur is in the application menu")
	}
	setup_show(app)
}

@(private = "file")
setup_remove :: proc(app: ^App) {
	if why := integration_remove(); why != "" {
		say(app, "Not removed: %s", why)
	} else {
		say(app, "Inspecteur's menu entry and icon are gone")
	}
	setup_show(app)
}

// The logo, `side` wide (a texture of the window's renderer, made once).
@(private = "file")
setup_logo :: proc(app: ^App, side: f32) {
	p := &app.setup
	if !p.logo_made {
		p.logo_made = true
		png := identity.ICONS[5].png   // (128 pixels)
		if img, ok := platform.clipboard_image_decode("image/png", png, context.temp_allocator); ok {
			p.logo = render.create_texture_rgba(&app.shared.r, img.size.x, img.size.y)
			render.update_texture_rgba(&app.shared.r, p.logo, 0, 0, img.size.x, img.size.y, img.rgba)
		}
	}
	d := ui.frame_new(Logo_Draw)
	d.tex = p.logo
	ui.next({width = ui.px(side), height = ui.px(side)})
	ui.custom("###setup_logo", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
		d := (^Logo_Draw)(user)
		if d.tex == {} { return }
		draw.image(dc, d.tex, {b.rect.min, b.rect.max})
	}, d)
}

@(private = "file")
Logo_Draw :: struct { tex: render.Texture }
