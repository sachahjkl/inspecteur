package inspecteur

// Inspecteur on the user's desktop (the toolkit's gt:desktop): its desktop entry in the application menu
// ($XDG_DATA_HOME/applications/inspecteur.desktop: Categories=System;Monitor;, an action per section) and its icon in the
// hicolor theme ($XDG_DATA_HOME/icons/hicolor/<n>x<n>/apps/inspecteur.png). It integrates the running executable where
// it is: a build, or a copy the user keeps. The Nix package installs the same entry and icons itself
// (inspecteurtool desktop_files): a copy that runs from the Nix store has nothing to install.
//
//   inspecteur setup               the entry and the icons, for this executable
//   inspecteur setup --uninstall   both taken away
//   inspecteur setup --status      what is there
//
// No autostart: a task manager is opened when it is needed.

import "core:fmt"
import "core:os"
import "core:strings"
import desktop "gt:desktop"
import process "gt:process"
import identity "identity"

// What the integration is now (owned strings).
Integration :: struct {
	nix:       bool,     // this copy runs from the Nix store: its package installs the entry
	installed: bool,     // the entry and the icons are there, for this executable
	repair:    bool,     // some of it is there, or it points to another executable
	other_exe: string,   // the other executable an entry runs
	entry:     string,   // where the entry is (or would be)
}

integration_free :: proc(it: ^Integration) {
	delete(it.other_exe)
	delete(it.entry)
	it^ = {}
}

@(private = "file")
integration_options :: proc() -> desktop.Options {
	o := desktop.options_make(identity.identity())
	o.exe = process.executable_path()
	o.icons = identity.ICONS[:]
	desktop.roots_from_env(&o, proc(name: string) -> string { return os.get_env(name, context.temp_allocator) })
	return o
}

integration_status :: proc() -> (it: Integration) {
	o := integration_options()
	it.nix = strings.has_prefix(o.exe, "/nix/store/")
	s := desktop.status(&o)
	defer desktop.status_destroy(&s)
	it.installed = s.state == .Installed
	it.repair = s.state == .Repair
	it.other_exe = strings.clone(s.stale_exe)
	apps := o.applications_dir
	if apps == "" {
		data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
		if data == "" { data = fmt.tprintf("%s/.local/share", os.get_env("HOME", context.temp_allocator)) }
		apps = fmt.tprintf("%s/applications", data)
	}
	it.entry = fmt.aprintf("%s/%s.desktop", apps, identity.SLUG)
	return
}

// Writes the entry and the icons; "" when done, else why not (temporary allocator).
integration_install :: proc() -> string {
	o := integration_options()
	if r := desktop.install(&o); r.error != .None { return fmt.tprintf("%s %s", desktop.error_text(r.error), r.detail) }
	return ""
}

// Takes the entry and the icons away; "" when done, else why not.
integration_remove :: proc() -> string {
	o := integration_options()
	if r := desktop.remove(&o); r.error != .None { return fmt.tprintf("%s %s", desktop.error_text(r.error), r.detail) }
	return ""
}

// `inspecteur setup [--uninstall | --status]`.
cmd_setup :: proc(args: []string) -> int {
	verb := len(args) > 0 ? args[0] : ""
	it := integration_status()
	defer integration_free(&it)
	switch verb {
	case "":
		if it.nix { fmt.println("inspecteur: this copy is the Nix package's: its desktop entry and icons come with it"); return 0 }
		if why := integration_install(); why != "" { fmt.eprintfln("inspecteur: %s", why); return 1 }
		fmt.printfln("inspecteur: in the application menu (%s), with its icon", it.entry)
		fmt.println(TASK_MANAGER_HINT)
		return 0
	case "--uninstall":
		if why := integration_remove(); why != "" { fmt.eprintfln("inspecteur: %s", why); return 1 }
		fmt.println("inspecteur: the desktop entry and the icons are gone (the preferences stay)")
		return 0
	case "--status":
		switch {
		case it.nix:       fmt.println("inspecteur: installed by Nix (this copy runs from the Nix store)")
		case it.installed: fmt.printfln("inspecteur: in the application menu (%s)", it.entry)
		case it.repair:    fmt.printfln("inspecteur: partly installed%s: `inspecteur setup` repairs it", it.other_exe != "" ? fmt.tprintf(", for %s", it.other_exe) : "")
		case:              fmt.println("inspecteur: not in the application menu: `inspecteur setup` adds it")
		}
		return it.installed || it.nix ? 0 : 1
	}
	fmt.eprintln("inspecteur setup [--uninstall | --status]")
	return 2
}

// How a desktop is told to open inspecteur as its task manager.
TASK_MANAGER_HINT :: `To open it as the desktop's task manager:
  shojiwm-win7: set SHOJIWM_WIN7_TASK_MANAGER=inspecteur in the session's environment (NixOS: environment.sessionVariables)
  another desktop: bind Ctrl+Shift+Escape to the command inspecteur in its keyboard settings`
