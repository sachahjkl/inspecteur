package inspecteur

// How the desktop of the session opens Inspecteur as its task manager, by the desktop $XDG_CURRENT_DESKTOP names:
//
//   shojiwm-win7   it opens the program SHOJIWM_WIN7_TASK_MANAGER names
//   GNOME          a custom keyboard shortcut (gsettings, the keys Settings shows): Inspecteur can add it itself
//   KDE Plasma     a custom shortcut in System Settings (Ctrl+Esc is Plasma's own System Monitor)
//   another        its keyboard settings: Ctrl+Shift+Escape runs `inspecteur`

import "core:fmt"
import "core:os"
import "core:strings"
import "gt:ascii"

Task_Manager_Hint :: struct {
	desktop:    string,   // "GNOME", "" for a desktop it does not know
	steps:      string,   // what to do, in words
	copy_label: string,   // a button that copies `copy` ("" none)
	copy:       string,
	can_bind:   bool,     // Inspecteur can add the shortcut itself (task_manager_bind)
}

// The desktop of this session, as $XDG_CURRENT_DESKTOP names it ("GNOME", "KDE", "shojiwm-win7"; "" unknown).
current_desktop :: proc() -> string { return os.get_env("XDG_CURRENT_DESKTOP", context.temp_allocator) }

// The hint for the desktop `desktop` (current_desktop's).
task_manager_hint :: proc(desktop: string) -> (h: Task_Manager_Hint) {
	current := ascii.lower(desktop, context.temp_allocator)
	switch {
	case strings.contains(current, "shojiwm"):
		h.desktop = "shojiwm-win7"
		h.steps = "shojiwm-win7 opens the program SHOJIWM_WIN7_TASK_MANAGER names: set it to inspecteur in the session's environment (on NixOS, environment.sessionVariables)."
		h.copy_label, h.copy = "Copy SHOJIWM_WIN7_TASK_MANAGER=inspecteur", "SHOJIWM_WIN7_TASK_MANAGER=inspecteur"
	case strings.contains(current, "gnome"):
		h.desktop = "GNOME"
		h.steps = "Add Shortcut binds Ctrl+Shift+Escape to inspecteur, as Settings > Keyboard > Custom Shortcuts would."
		h.can_bind = true
	case strings.contains(current, "kde"):
		h.desktop = "KDE Plasma"
		h.steps = "System Settings > Keyboard > Shortcuts > Add New > Command or Script: inspecteur, then press Ctrl+Shift+Escape (Ctrl+Esc stays Plasma's System Monitor)."
		h.copy_label, h.copy = "Copy the command", "inspecteur"
	case:
		h.steps = "Bind Ctrl+Shift+Escape to the command inspecteur in the desktop's keyboard settings."
		h.copy_label, h.copy = "Copy the command", "inspecteur"
	}
	return
}

// GNOME's custom shortcuts: a list of paths, and a relocatable schema at each path.
@(private = "file") GNOME_KEYS :: "org.gnome.settings-daemon.plugins.media-keys"
@(private = "file") GNOME_PATH :: "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/inspecteur/"

// GNOME: the shortcut Ctrl+Shift+Escape that runs `inspecteur`, added to the user's custom shortcuts (the others stay).
// Returns "" when done, else why not (temporary).
task_manager_bind :: proc() -> string {
	list, ok := gsettings({"get", GNOME_KEYS, "custom-keybindings"})
	if !ok { return "gsettings cannot read the shortcuts" }
	list = strings.trim_space(list)
	if !strings.contains(list, GNOME_PATH) {
		item := fmt.tprintf("'%s'", GNOME_PATH)
		switch {
		case list == "@as []" || list == "[]": list = fmt.tprintf("[%s]", item)
		case strings.has_suffix(list, "]"):    list = fmt.tprintf("%s, %s]", list[:len(list) - 1], item)
		case:                                  return "gsettings gave a list it does not know"
		}
		if _, set := gsettings({"set", GNOME_KEYS, "custom-keybindings", list}); !set { return "gsettings cannot write the shortcuts" }
	}
	schema := fmt.tprintf("%s.custom-keybinding:%s", GNOME_KEYS, GNOME_PATH)
	for kv in ([][2]string{{"name", "Inspecteur"}, {"command", "inspecteur"}, {"binding", "<Control><Shift>Escape"}}) {
		if _, set := gsettings({"set", schema, kv[0], kv[1]}); !set { return "gsettings cannot write the shortcut" }
	}
	return ""
}

@(private = "file")
gsettings :: proc(args: []string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "gsettings")
	append(&cmd, ..args)
	state, stdout, _, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
	return string(stdout), err == nil && state.exited && state.exit_code == 0
}
