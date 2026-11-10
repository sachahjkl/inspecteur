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

// journalctl -o json: its fields as strings, a MESSAGE that is not UTF-8 as an array of bytes, an identifier from _COMM
// when SYSLOG_IDENTIFIER is not there, a line that is not JSON left out.
@(test)
a_journal_entry_reads_from_json :: proc(t: ^testing.T) {
	e, ok := journal_entry_parse(`{"__REALTIME_TIMESTAMP":"1762800000123456","PRIORITY":"3","_PID":"812","SYSLOG_IDENTIFIER":"nginx","MESSAGE":"bind() failed\n"}`, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, e.usec, i64(1762800000123456))
	testing.expect_value(t, e.priority, u8(3))
	testing.expect_value(t, e.pid, i32(812))
	testing.expect_value(t, e.ident, "nginx")
	testing.expect_value(t, e.message, "bind() failed")
	b, bok := journal_entry_parse(`{"__REALTIME_TIMESTAMP":"1","_COMM":"sh","MESSAGE":[104,105]}`, context.temp_allocator)
	testing.expect(t, bok)
	testing.expect_value(t, b.message, "hi")
	testing.expect_value(t, b.ident, "sh")
	testing.expect_value(t, b.priority, u8(6))   // (no PRIORITY: info)
	_, bad := journal_entry_parse("-- No entries --", context.temp_allocator)
	testing.expect(t, !bad)
	testing.expect(t, journal_level_keeps(.Errors, 3) && !journal_level_keeps(.Errors, 4))
	testing.expect(t, journal_level_keeps(.Warnings, 4) && !journal_level_keeps(.Warnings, 5))
}
