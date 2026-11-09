package inspecteur

import "core:testing"

@(test)
stat_line_is_read :: proc(t: ^testing.T) {
	// a name with a space and parentheses: it ends at the last ')'
	line := "4242 (Web (Content) x) S 4100 4242 4100 0 -1 4194560 1 0 0 0 120 30 0 0 20 0 27 0 987654 1234567 5000 18446744073709551615 0 0 0 0 0 0 0 4096 0 0 0 0 17 3 0 0 0 0 0\n"
	f, ok := parse_stat(line)
	testing.expect(t, ok)
	testing.expect_value(t, f.comm, "Web (Content) x")
	testing.expect_value(t, f.ppid, i32(4100))
	testing.expect_value(t, f.ticks, u64(150))
	testing.expect_value(t, f.threads, i32(27))
	testing.expect_value(t, f.start, u64(987654))
	testing.expect_value(t, f.rss_pages, u64(5000))
	testing.expect(t, f.flags & PF_KTHREAD == 0)
	_, cut := parse_stat("12 (x) S 1 2 3")
	testing.expect(t, !cut, "a line cut short is refused")
}

@(test)
machine_times_are_read :: proc(t: ^testing.T) {
	text := "cpu  100 5 50 800 20 3 2 1 9 0\ncpu0 50 2 25 400 10 1 1 0 0 0\ncpu1 50 3 25 400 10 2 1 1 0 0\nintr 1 2 3\n"
	c := parse_cpu_times(text)
	testing.expect_value(t, c.total, u64(100 + 5 + 50 + 800 + 20 + 3 + 2 + 1))
	testing.expect_value(t, c.idle, u64(820))
	testing.expect_value(t, c.cores, 2)
	m := parse_meminfo("MemTotal:       32000000 kB\nMemFree:  100 kB\nMemAvailable:   20000000 kB\n")
	testing.expect_value(t, m.total, u64(32000000) * 1024)
	testing.expect_value(t, m.available, u64(20000000) * 1024)
	io := parse_io("rchar: 10\nwchar: 20\nsyscr: 1\nsyscw: 2\nread_bytes: 4096\nwrite_bytes: 8192\ncancelled_write_bytes: 0\n")
	testing.expect_value(t, io.read, u64(4096))
	testing.expect_value(t, io.write, u64(8192))
}

@(test)
names_are_shown_whole_and_unwrapped :: proc(t: ^testing.T) {
	testing.expect_value(t, display_name(".firefox-wrappe", "/nix/store/abc-firefox/bin/.firefox-wrapped", ""), "firefox")
	testing.expect_value(t, display_name("gnome-terminal-", "/usr/bin/gnome-terminal-server", ""), "gnome-terminal-server")
	testing.expect_value(t, display_name("bash", "-bash", "/usr/bin/bash"), "bash")
	testing.expect_value(t, display_name("sleep", "sleep\x00300", ""), "sleep")
	testing.expect_value(t, display_name(".quickshell-wra", "qs", "/nix/store/x/bin/.quickshell-wrapped"), "quickshell")
	testing.expect_value(t, cgroup_scope("0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-firefox-1234.scope\n"), "app-firefox-1234.scope")
}

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
processes_match_their_apps :: proc(t: ^testing.T) {
	c: Catalog
	defer catalog_destroy(&c)
	catalog_add(&c, "org.chromium.Chromium", "[Desktop Entry]\nType=Application\nName=Chromium\nExec=chromium %U\nIcon=chromium\n")
	catalog_add(&c, "com.mitchellh.ghostty", "[Desktop Entry]\nType=Application\nName=Ghostty\nExec=/nix/store/x-ghostty/bin/ghostty\nStartupWMClass=com.mitchellh.ghostty\n")
	catalog_add(&c, "htop", "[Desktop Entry]\nType=Application\nName=htop\nExec=htop\nTerminal=true\n")
	catalog_add(&c, "hidden", "[Desktop Entry]\nType=Application\nName=Hidden\nExec=hidden\nNoDisplay=true\n")
	testing.expect_value(t, len(c.entries), 2)
	testing.expect_value(t, catalog_match(&c, "chromium", "", ""), 0)
	testing.expect_value(t, catalog_match(&c, "ghostty", "", ""), 1)
	testing.expect_value(t, catalog_match(&c, "fish", "/usr/bin/fish", "app-ShojiWM-ghostty-d5e1a437.scope"), 1)
	testing.expect_value(t, catalog_match(&c, "x", "", "app-org.chromium.Chromium-56418.scope"), 0)
	testing.expect_value(t, catalog_match(&c, "htop", "/usr/bin/htop", "session-8.scope"), -1)
	testing.expect_value(t, catalog_match(&c, "hidden", "", ""), -1)
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
