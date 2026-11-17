// What inspecteur is to the desktop: its names, its desktop entry's actions and its icons. The program (integration.odin:
// `inspecteur setup`, the welcome page) and inspecteurtool (`desktop_files`: what the Nix package installs) both write
// the entry from here.
package inspecteur_identity

import desktop "gt:desktop"

SLUG :: "inspecteur"

// A launcher's right click opens these sections at once (`inspecteur --section <name>`).
ACTIONS := [?]desktop.Desktop_Action{
	{id = "performance", name = "Performance", arguments = "--section performance"},
	{id = "services", name = "Services", arguments = "--section services"},
	{id = "startup", name = "Startup", arguments = "--section startup"},
	{id = "connections", name = "Connections", arguments = "--section connections"},
	{id = "information", name = "Information", arguments = "--section information"},
}

// The logo in the sizes of the hicolor theme (assets/logo_<n>.png, drawn by `inspecteurtool logo`).
ICONS := [?]desktop.Icon{
	{16, #load("../../assets/logo_16.png")},
	{24, #load("../../assets/logo_24.png")},
	{32, #load("../../assets/logo_32.png")},
	{48, #load("../../assets/logo_48.png")},
	{64, #load("../../assets/logo_64.png")},
	{128, #load("../../assets/logo_128.png")},
	{256, #load("../../assets/logo_256.png")},
	{512, #load("../../assets/logo_512.png")},
}

// The marks (the entry's, the registry's, the manifest's name, the environment's prefix) follow the toolkit's rule
// (desktop.identity_of): the installed copies carry the same. Its strings are allocated: a caller makes it once per use
// (the setup's options, the Nix package's entry). Its uninstall_arguments are the setup's (setup.odin): only the setup
// writes an uninstall entry; the Nix package's has none.
identity :: proc(allocator := context.allocator) -> desktop.Identity {
	id := desktop.identity_of("Froment Software", "Inspecteur", SLUG, allocator)
	id.description = "What runs on this computer: its processes, performance, services, startup and connections."
	id.generic_name = "Task Manager"
	id.categories = "System;Monitor;"
	id.keywords = "task;manager;process;monitor;cpu;memory;kill;services;startup;network;"
	id.actions = ACTIONS[:]
	return id
}
