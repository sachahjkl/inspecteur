package inspecteur

import "core:testing"

@(test)
sizes_are_human :: proc(t: ^testing.T) {
	testing.expect_value(t, size_text(512), "512 B")
	testing.expect_value(t, size_text(1536), "1.5 KB")
	testing.expect_value(t, size_text(300 * 1024 * 1024), "300 MB")
	testing.expect_value(t, size_text(u64(5) * 1024 * 1024 * 1024), "5.0 GB")
	testing.expect_value(t, rate_text(0.5), "")
	testing.expect_value(t, rate_text(2048), "2.0 KB/s")
}

@(test)
apps_take_their_children :: proc(t: ^testing.T) {
	// 1 init, 10 ghostty (app 0), 11 fish under it, 12 chromium (app 1) started from fish, 13 its child, 20 a daemon,
	// 30 a second ghostty
	procs := []Proc{
		{pid = 1, ppid = 0, entry = -1},
		{pid = 10, ppid = 1, entry = 0},
		{pid = 11, ppid = 10, entry = -1},
		{pid = 12, ppid = 11, entry = 1},
		{pid = 13, ppid = 12, entry = 1},
		{pid = 20, ppid = 1, entry = -1},
		{pid = 30, ppid = 1, entry = 0},
	}
	tb: Table
	defer table_destroy(&tb)
	table_group(&tb, procs)
	testing.expect_value(t, len(tb.groups), 2)
	testing.expect_value(t, len(tb.background), 2)
	for g in tb.groups {
		roots := group_roots(&tb, g)
		switch g.entry {
		case 0:
			testing.expect_value(t, g.count, 3)   // both ghostty and fish
			testing.expect_value(t, len(roots), 2)
		case 1:
			testing.expect_value(t, g.count, 2)
			testing.expect(t, len(roots) == 1 && procs[roots[0]].pid == 12, "the app's process is the highest of the app")
		}
	}
}

// A unit's name escapes a '-' of the desktop id (\x2d): the parts are split first, then unescaped.
@(test)
a_scope_names_its_app :: proc(t: ^testing.T) {
	c: Catalog
	defer catalog_destroy(&c)
	catalog_add_entry(&c, "org.gnome.Text-Editor", "Text Editor", "", "gnome-text-editor", "")
	testing.expect_value(t, catalog_match(&c, "x", "", "app-gnome-org.gnome.Text\\x2dEditor-1234.scope"), 0)
	testing.expect_value(t, catalog_match(&c, "x", "", "app-org.gnome.Text\\x2dEditor@autostart.service"), 0)
	testing.expect_value(t, catalog_match(&c, "x", "", "session-3.scope"), -1)
}

// A launcher or an interpreter is no app: past a launcher the program is further on, and an interpreter's is its script.
@(test)
launchers_and_interpreters_name_no_app :: proc(t: ^testing.T) {
	testing.expect_value(t, program_of({"env", "FOO=1", "sudo", "-u", "alex", "/usr/bin/firefox", "%U"}), "firefox")
	testing.expect_value(t, program_of({"python3", "-u", "/opt/app/main.py"}), "main.py")
	testing.expect_value(t, program_of({"sh", "-c", "exec foo --x"}), "foo")
	testing.expect_value(t, program_of({"flatpak", "run", "--branch=stable", "org.gnome.Maps"}), "org.gnome.Maps")
	testing.expect_value(t, program_of({"python3"}), "")
	testing.expect_value(t, program_of({"python3.12", "-m", "app"}), "app")
	testing.expect_value(t, program_of({"nice", "-n", "5", "make"}), "make")
	testing.expect_value(t, program_of({"systemd-run", "--user", "--unit", "x", "--", "electron32", "/opt/notes/app.asar"}), "app.asar")
	c: Catalog
	defer catalog_destroy(&c)
	catalog_add_entry(&c, "org.example.Notes", "Notes", "", program_of({"python3", "/opt/notes/notes.py"}), "")
	catalog_add_entry(&c, "terminal", "Terminal", "", program_of({"bash", "-c", "terminal --login"}), "")
	testing.expect_value(t, catalog_match(&c, "python3", "/usr/bin/python3.12", "", "python3 /opt/notes/notes.py --x"), 0)
	testing.expect_value(t, catalog_match(&c, "python3", "/usr/bin/python3.12", "", "python3 /opt/other.py"), -1)
	testing.expect_value(t, catalog_match(&c, "bash", "/usr/bin/bash", "", "bash"), -1)
	testing.expect_value(t, catalog_match(&c, "terminal", "", ""), 1)
}
