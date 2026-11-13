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
	return setup.Setup_Options{identity = id, version = APP_VERSION, install_folder = APP_NAME, icons = identity.ICONS[:], running = one_copy_running}
}

// The updates start once the start's reading of the install says which copy runs (an installed copy updates itself in
// place; another copy says where the new one is).
setup_follow :: proc(app: ^App) {
	if app.updates_asked || !app.install.known { return }
	app.updates_asked = true
	updates_start(app, app.install.running_it, app.install.running)
}
