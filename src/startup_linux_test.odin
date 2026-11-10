package inspecteur

import "core:testing"

@(test)
an_autostart_entry_says_when_it_starts :: proc(t: ^testing.T) {
	text := "[Desktop Entry]\nType=Application\nName=Syncer\nExec=syncer --tray\nIcon=syncer\nOnlyShowIn=GNOME;KDE;\n"
	e := autostart_entry(text, {"KDE"})
	testing.expect_value(t, e.name, "Syncer")
	testing.expect_value(t, e.exec, "syncer --tray")
	testing.expect(t, e.application && e.enabled && e.in_desktop)
	testing.expect(t, !autostart_entry(text, {"sway"}).in_desktop)
	testing.expect(t, !autostart_entry(text, {}).in_desktop)
	testing.expect(t, !autostart_entry("[Desktop Entry]\nName=A\nNotShowIn=sway;\n", {"sway"}).in_desktop)
	testing.expect(t, !autostart_entry("[Desktop Entry]\nName=A\nHidden=true\n", {}).enabled)
	testing.expect(t, !autostart_entry("[Desktop Entry]\nName=A\nX-GNOME-Autostart-enabled=false\n", {}).enabled)
	testing.expect(t, !autostart_entry("[Desktop Entry]\nType=Link\nName=A\n", {}).application)
}

@(test)
a_desktop_entry_key_is_set_where_it_is :: proc(t: ^testing.T) {
	text := "[Desktop Entry]\nName=A\nHidden=false\nExec=a\n[Desktop Action New]\nHidden=keep\n"
	testing.expect_value(t, desktop_entry_set(text, "Hidden", "true"), "[Desktop Entry]\nName=A\nHidden=true\nExec=a\n[Desktop Action New]\nHidden=keep\n")
	testing.expect_value(t, desktop_entry_set(text, "Hidden", ""), "[Desktop Entry]\nName=A\nExec=a\n[Desktop Action New]\nHidden=keep\n")
	testing.expect_value(t, desktop_entry_set("[Desktop Entry]\nName=A\n", "Hidden", "true"), "[Desktop Entry]\nName=A\nHidden=true\n")
	testing.expect_value(t, desktop_entry_set("[Desktop Entry]\nName=A\n[Other]\nX=1\n", "Hidden", "true"), "[Desktop Entry]\nName=A\nHidden=true\n[Other]\nX=1\n")
}

@(test)
an_exec_start_loses_its_prefixes :: proc(t: ^testing.T) {
	testing.expect_value(t, exec_command("-@/usr/bin/foo --bar"), "/usr/bin/foo --bar")
	testing.expect_value(t, exec_command("/usr/bin/foo"), "/usr/bin/foo")
}

@(test)
a_store_path_is_shown_by_its_program :: proc(t: ^testing.T) {
	testing.expect_value(t, command_shown("/nix/store/abc-foo-1.2/bin/foo -x --y"), "foo -x --y")
	testing.expect_value(t, command_shown("/usr/bin/foo -x"), "/usr/bin/foo -x")
	testing.expect_value(t, command_shown("nm-applet"), "nm-applet")
}
