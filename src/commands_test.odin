package inspecteur

import "core:slice"
import "core:strings"
import "core:testing"
import config "gt:config"
import lucide "gt:lucide"
import "gt:testkit/session"
import "gt:ui"

// A key that types text works only while no field has the keyboard (gui_toolkit's src/md/features/commands.md): Space
// toggles a startup entry from the list, and is the filter's while it has the keyboard. A new one is listed here on
// purpose.
@(test)
the_keys_that_type_text :: proc(t: ^testing.T) {
	got := ui.command_typing_keys(slice.enumerated_array(&COMMANDS))
	testing.expectf(t, slice.equal(got, []string{"Enable or disable: Space"}), "keys that type text: %v", got)
}

// The keys and the settings are the window's: their keys work in the settings, in a view with the keyboard, over a
// dialog (window_keys); none types text. (The palette's command is the toolkit's: COMMANDS has no line for it, and no
// command takes its keys.) The live run opens the palette from the settings.
@(test)
the_window_commands :: proc(t: ^testing.T) {
	palette := ui.palette_command()
	for c in Cmd {
		want := c == .Shortcuts || c == .Settings
		testing.expectf(t, (COMMANDS[c].scope == .Window) == want, "%v: the window's is %v", c, want)
		for k in COMMANDS[c].keys { testing.expectf(t, !slice.contains(palette.keys, k), "%v takes the palette's key %v", c, k) }
	}
	testing.expect_value(t, len(ui.command_window_typing_keys(slice.enumerated_array(&COMMANDS))), 0)
}

// The palette's prefixes are those meant (gui_toolkit's one table): the commands and the views' moves, Go to (the
// processes and the services), the settings.
@(test)
the_palettes_prefixes :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	ui.palette_commands(&app.palette, slice.enumerated_array(&COMMANDS), nil)
	go_to_add(app)
	palette_settings_add(app)
	got := ui.palette_prefixes(&app.palette)
	testing.expectf(t, slice.equal(got, []string{"> Commands", "@ Go to", ": Settings"}), "prefixes: %v", got)
	ui.palette_destroy(&app.palette)
}

// A Go to process item's id names its process (pid and start) and reads back.
@(test)
go_to_ids_read_back :: proc(t: ^testing.T) {
	pid, start, ok := go_to_process_parse(go_to_process_id(4242, 987654321))
	testing.expect(t, ok && pid == 4242 && start == 987654321)
	_, _, bad := go_to_process_parse("x:1")
	testing.expect(t, !bad)
}

// Every command has a well-formed id of its own: the person's keys, aliases and the palette's memory are stored under it.
@(test)
the_command_ids :: proc(t: ^testing.T) {
	problems := ui.command_ids_check(slice.enumerated_array(&COMMANDS))
	testing.expectf(t, len(problems) == 0, "command ids: %v", problems)
}

// Every command has its icon (the palette shows it before the label) and its label.
@(test)
every_command_has_an_icon :: proc(t: ^testing.T) {
	for c in Cmd {
		testing.expectf(t, COMMANDS[c].icon != "", "%v has an icon", c)
		testing.expectf(t, COMMANDS[c].label != "", "%v has a label", c)
	}
}

// What the build of a command's button stated: its act name, and a button's that runs no command.
@(private = "file")
Act_Probe :: struct {
	app:          ^App,
	named, plain: bool,
}

// A command's button states its act name at its build (ui.act_command): the palette's Shift+Enter on the command goes
// to it. A tool button given no command states none.
@(test)
a_command_s_button_states_its_act_name :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	probe := Act_Probe{app = app}
	s := session.start(t, {size = {800, 200}, user = &probe, no_renderer = true, build = proc(s: ^session.Session) {
		pr := (^Act_Probe)(s.user)
		// (what the last frame stated: a frame's act names are the window's at its end)
		pr.named = ui.act_shown("command:properties")
		pr.plain = ui.act_shown("command:kill")
		em := ui.font_size()
		ui.next({width = ui.fill(), height = ui.px(em * BAR_EM)})
		if ui.row(.Center, id = "###bar") {
			cmd_button(pr.app, "properties", lucide.INFO, .Properties, em)
			_ = tool_button("kill", lucide.ZAP, "", true, em)
		}
	}})
	session.frames(s, 2)
	testing.expect_value(t, COMMANDS[.Properties].id, "properties")
	testing.expect(t, probe.named, "the Properties button states command:properties")
	testing.expect(t, !probe.plain, "a button given no command states none")
}

// Processes of the demo's kind for the commands with arguments: no process of the system (app.demo set: nothing is
// sent, set or written to a process; the footer says what would have been), the first background process selected.
demo_rows :: proc() -> ^App {
	app := new(App)
	app.demo = new(Demo)
	append(&app.sampler.procs,
		Proc{pid = 20, ppid = 1, entry = -1, name = "a", search = "a", start = 1},
		Proc{pid = 21, ppid = 1, entry = -1, name = "b", search = "b", start = 1})
	table_columns_init(&app.table)
	table_group(&app.table, app.sampler.procs[:])
	table_rows(&app.table, &app.sampler, &app.catalog)
	for r, i in app.table.rows {
		if r.kind == .Process && app.sampler.procs[r.index].pid == 20 { select_row(app, i); break }
	}
	return app
}

demo_rows_free :: proc(app: ^App) {
	delete(app.status)
	free(app.demo)
	catalog_destroy(&app.catalog)
	table_destroy(&app.table)
	delete(app.sampler.procs)
	ui.vlist_destroy(&app.vl)
	free(app)
}

// Each command with arguments offers a closed list, its default among it: the form opens on a value it can run.
@(test)
every_argument_offers_its_default :: proc(t: ^testing.T) {
	for c in Cmd {
		for a in COMMANDS[c].arguments {
			labels, values := command_choices(nil, 0, a.name)
			testing.expectf(t, len(values) > 0 && len(labels) == len(values), "%v: %s is a closed list", c, a.name)
			testing.expectf(t, slice.contains(values, a.default.s), "%v: %s's default %q is one of its values", c, a.name, a.default.s)
		}
	}
}

// Set the priority with its form's value: the row selected gets that priority.
@(test)
set_the_priority_takes_its_form_s_priority :: proc(t: ^testing.T) {
	app := demo_rows()
	defer demo_rows_free(app)
	_, values := command_choices(app, 0, "priority")
	if !testing.expect(t, len(values) == len(PRIORITIES), "every priority is offered") { return }
	last := PRIORITIES[len(PRIORITIES) - 1]
	testing.expect(t, cmd_can(app, .Set_Priority), "a process is selected")
	cmd_run_with(app, .Set_Priority, {values[len(values) - 1]})
	testing.expectf(t, strings.contains(app.status, priority_text(last.nice)) && strings.contains(app.status, "a (PID 20)"), "the footer: %q", app.status)
	// (nothing selected: the command cannot act, and nothing is said)
	delete(app.status)
	app.status = ""
	app.vl.sel = -1
	cmd_run_with(app, .Set_Priority, {values[0]})
	testing.expect_value(t, app.status, "")
}

// Refresh speed with its form's value: the refresh takes that period, written to the preferences; a value the list does
// not offer changes nothing.
@(test)
refresh_speed_takes_its_form_s_period :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer delete(app.status)
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	config.register(&app.prefs, PREF_DEFS[:])
	app.settings.refresh_ms = 1000
	app.paused = true
	_, values := command_choices(app, 0, "period")
	testing.expect(t, slice.contains(values, "2000"), "2 s is offered")
	cmd_run_with(app, .Refresh_Speed, {"2000"})
	testing.expect_value(t, app.settings.refresh_ms, 2000)
	testing.expect_value(t, config.int_of(&app.prefs, "processes.refresh_ms"), 2000)
	testing.expect(t, !app.paused, "the refresh resumes")
	cmd_run_with(app, .Refresh_Speed, {"1234"})
	testing.expect_value(t, app.settings.refresh_ms, 2000)
}
