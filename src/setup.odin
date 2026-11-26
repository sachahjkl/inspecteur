package inspecteur

// Setup: inspecteur installs itself for the user from the copy that was downloaded (gui_toolkit's setup and its
// prefs_page.Install: docs/setup.md, docs/prefs_page.md): the program in ~/.local/share/inspecteur, its menu entry (a
// section per action of its right click), its icons and the install's manifest, which Uninstall reads. A start of a copy
// that is not installed offers it, once per version, unless the user keeps this copy standalone (install.choice). The
// settings' Installation page shows the install and acts on it. A copy that runs from the Nix store is the Nix package's:
// Nix installs and updates it, nothing is offered. On NixOS a classic install makes its copy run by itself (a Nix
// profile of NIXOS_LIBRARIES).
//
//   inspecteur --install     the install, from the command line
//   inspecteur --uninstall   it all taken away (the preferences stay)
//   inspecteur --status      what is installed, and whether Inspecteur runs (exit 0 installed, 2 to repair, 1 not)
//   inspecteur --setup       the window, the install's dialog open
//
// On Windows an install for everyone offers Inspecteur in place of Task Manager (src/md/features/install.md): Windows
// then starts that install with taskmgr's path (main.odin, setup.task_manager_start).

import "core:os"
import desktop "gt:desktop"
import "gt:i18n"
import setup "gt:setup"
import identity "identity"

// What inspecteur needs from the system on NixOS, by nixpkgs attribute: what it links (glibc; libgcc_s is in
// stdenv.cc.cc), what it opens with dlopen (flake.nix's runtime, without mesa: the Vulkan driver is the system's) and
// libcurl, which the updates fetch with.
@(rodata)
NIXOS_LIBRARIES := [?]string{
	"glibc", "stdenv.cc.cc",
	"vulkan-loader", "libxkbcommon", "wayland", "libx11", "libxcb", "libxcb-cursor", "fontconfig", "freetype", "dbus",
	"curl",
}

// What the setup knows of inspecteur.
setup_options :: proc() -> setup.Setup_Options {
	id := identity.identity()
	id.nix_runtime_name = "inspecteur-runtime"
	id.nixos_libraries = NIXOS_LIBRARIES[:]
	id.uninstall_arguments = "--setup"   // (Settings > Apps: the install's dialog, its Uninstall)
	return setup.Setup_Options{
		identity = id, version = APP_VERSION, icons = identity.ICONS[:], running = one_copy_running, quit = one_copy_quit,
		vendor_url = "https://froment.software", choices = setup_choices(),
		prepare = proc(o: ^desktop.Integration_Options, choices: []bool, user: rawptr) {
			for x, i in setup_choices() {
				if i >= len(choices) { break }
				if .Path in x.parts { o.add_to_path = choices[i] }
				if .Task_Manager in x.parts { o.task_manager = choices[i] }
			}
			desktop.roots_from_env(o, env_lookup)   // (a test's places: nothing of the person's)
		},
	}
}

// (not rodata: i18n.later marks the labels for the catalogue; tr where they are shown)
// Each box is tied to its part (src/md/features/install.md): with an install there, it shows what the system has, and
// what is ticked is what Install writes. The task manager's words are the system's (system_<os>.odin).
@(private = "file")
SETUP_CHOICES := [?]setup.Choice{
	{label = i18n.later("Inspecteur in the terminal (on the PATH)"), on = true, parts = {.Path}},
	{label = SETUP_TASK_MANAGER_WORDS, on = false, parts = {.Task_Manager}},
}

// The boxes this system has: the task manager's only where the system has the part (Windows).
setup_choices :: proc() -> []setup.Choice {
	return .Task_Manager in desktop.supported_parts() ? SETUP_CHOICES[:] : SETUP_CHOICES[:1]
}

// (the places of a test come from the environment: INSPECTEUR_DESKTOP_*)
@(private = "file")
env_lookup :: proc(name: string) -> string { return os.get_env(name, context.temp_allocator) }
