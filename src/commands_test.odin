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

// The palette, the keys and the settings are the window's: their keys work in the settings, in a view with the keyboard,
// over a dialog (window_keys); none types text. The live run opens the palette from the settings.
@(test)
the_window_commands :: proc(t: ^testing.T) {
	for c in Cmd {
		want := c == .Palette || c == .Shortcuts || c == .Settings
		testing.expectf(t, (COMMANDS[c].scope == .Window) == want, "%v: the window's is %v", c, want)
	}
	testing.expect_value(t, len(ui.command_window_typing_keys(slice.enumerated_array(&COMMANDS))), 0)
}

// Every command has its icon (the palette shows it before the label) and its label.
@(test)
every_command_has_an_icon :: proc(t: ^testing.T) {
	for c in Cmd {
		testing.expectf(t, COMMANDS[c].icon != "", "%v has an icon", c)
		testing.expectf(t, COMMANDS[c].label != "", "%v has a label", c)
	}
}
