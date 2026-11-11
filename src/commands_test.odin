package inspecteur

import "core:testing"

// Every command has its icon (the palette shows it before the label) and its label.
@(test)
every_command_has_an_icon :: proc(t: ^testing.T) {
	for c in Cmd {
		testing.expectf(t, COMMANDS[c].icon != "", "%v has an icon", c)
		testing.expectf(t, COMMANDS[c].label != "", "%v has a label", c)
	}
}
