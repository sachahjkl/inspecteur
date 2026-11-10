package inspecteur

import "core:testing"

@(test)
a_unit_file_gives_its_values :: proc(t: ^testing.T) {
	text := "# a comment\n[Unit]\nDescription=First\nDescription = The service\n\n[Service]\nExecStart=/bin/true\nDescription=not this one\n[Install]\nWantedBy=default.target graphical-session.target\n"
	testing.expect_value(t, unit_file_value(text, "Unit", "Description"), "The service")
	testing.expect_value(t, unit_file_value(text, "Service", "ExecStart"), "/bin/true")
	testing.expect_value(t, unit_file_value(text, "Install", "WantedBy"), "default.target graphical-session.target")
	testing.expect_value(t, unit_file_value(text, "Unit", "Documentation"), "")
}
