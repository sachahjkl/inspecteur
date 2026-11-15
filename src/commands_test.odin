package inspecteur

import "core:slice"
import "core:testing"
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

// A Go to item's id names its process (pid and start) or its service (manager and name), and reads back.
@(test)
go_to_ids_read_back :: proc(t: ^testing.T) {
	pid, start, ok := go_to_process_parse(go_to_process_id(4242, 987654321))
	testing.expect(t, ok && pid == 4242 && start == 987654321)
	_, _, bad := go_to_process_parse("x:1")
	testing.expect(t, !bad)
	m, name, sok := go_to_service_parse(go_to_service_id(.User, "foo.service"))
	testing.expect(t, sok && m == .User && name == "foo.service")
	_, _, other := go_to_service_parse("nobody/foo.service")
	testing.expect(t, !other)
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
