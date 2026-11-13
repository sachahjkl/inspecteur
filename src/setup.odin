package inspecteur

// Setup: inspecteur installs itself for the user from the copy that was downloaded (gui_toolkit's setup, its
// docs/setup.md): the program in ~/.local/share/inspecteur, its menu entry (a section per action of its right click), its
// icons and the install's manifest, which Uninstall reads. A start of a copy that is not installed offers it, once per
// version, unless the user keeps this copy standalone (setup.choice). A copy that runs from the Nix store is the Nix
// package's: Nix installs and updates it, nothing is offered. On NixOS a classic install makes its copy run by itself
// (a Nix profile of NIXOS_LIBRARIES).
//
//   inspecteur install     the install, from the command line
//   inspecteur uninstall   it all taken away (the preferences stay)
//   inspecteur status      the state; exit 0 installed (or a Nix package), 2 to repair, 1 not installed
//   inspecteur --setup     the window, the dialog open (the palette: Install…)

import "core:fmt"
import "core:strings"
import desktop "gt:desktop"
import "gt:platform"
import "gt:render"
import setup "gt:setup"
import "gt:ui"
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

// The logo of the dialog: the 128-pixel icon.
@(private = "file") LOGO_ICON :: 5

// What the setup knows of inspecteur.
setup_config :: proc() -> setup.Setup_Options {
	id := identity.identity()
	id.nix_runtime_name = "inspecteur-runtime"
	id.nixos_libraries = NIXOS_LIBRARIES[:]
	return setup.Setup_Options{identity = id, version = APP_VERSION, install_folder = APP_NAME, icons = identity.ICONS[:]}
}

// What the setup's facts say at a start (setup.facts reads the install's files: a task of the chores).
@(private = "file")
Setup_Facts :: struct {
	choice:     string,   // owned: setup.choice
	offer:      bool,     // the dialog has something to do
	running_it: bool,     // this program is the installed copy
	exe:        string,   // owned: this program
}

// At a start with the window: the dialog when there is something to do, unless the user answered for this version or
// kept this copy standalone; then the updates (updates_start: they need to know which copy runs). Never in the demo, nor
// for the Nix package's copy (setup.wanted).
setup_offer :: proc(app: ^App, offer: bool) {
	if app.demo != nil { return }
	f := new(Setup_Facts)
	f^ = {choice = strings.clone(app.settings.setup_choice), offer = offer}
	ui.task(&app.main.state, setup_facts_work, setup_facts_done, f, setup_facts_free)
}

@(private = "file")
setup_facts_work :: proc(data: rawptr) {
	f := (^Setup_Facts)(data)
	facts := setup.facts(setup_config())
	f.offer = f.offer && setup.wanted(facts, APP_VERSION, f.choice)
	f.running_it = facts.running_it
	f.exe = strings.clone(facts.running)
}

@(private = "file")
setup_facts_done :: proc(data: rawptr, _: u64) {
	f := (^Setup_Facts)(data)
	defer setup_facts_free(f)
	app := the_app
	if app == nil || app.closing { return }
	if f.offer && !app.setup.open { setup.open(&app.setup, setup_config()) }
	updates_start(app, f.running_it, f.exe)
}

@(private = "file")
setup_facts_free :: proc(data: rawptr) {
	f := (^Setup_Facts)(data)
	delete(f.choice)
	delete(f.exe)
	free(f)
}

setup_open :: proc(app: ^App) { setup.open(&app.setup, setup_config()) }

// The dialog, over the window, while it is open; what the user answered is kept (setup.choice).
setup_build :: proc(app: ^App, em: f32) {
	if !app.setup.open { return }
	if !app.setup_logo_made { setup_logo(app) }
	logo: Maybe(setup.Logo)
	if app.setup_logo != {} { logo = setup.Logo{app.setup_logo, {128, 128}} }
	switch setup.dialog(&app.setup, setup_config(), em, logo) {
	case .Installed:       setup_choice(app, setup.CHOICE_INSTALLED)
	case .Kept_Standalone: setup_choice(app, setup.CHOICE_STANDALONE)
	case .Dismissed:       setup_choice(app, setup.choice_dismissed(APP_VERSION))
	case .Launched:        platform.request_close(app.main.win)   // (the installed copy runs)
	case .Uninstalled, .None:
	}
}

@(private = "file")
setup_choice :: proc(app: ^App, choice: string) {
	pref_set(&app.prefs, "setup.choice", choice)
	delete(app.settings.setup_choice)
	app.settings.setup_choice = fmt.aprintf("%s", choice)
}

// The logo of the dialog, a texture of the window's renderer (made once, freed with the window).
@(private = "file")
setup_logo :: proc(app: ^App) {
	app.setup_logo_made = true
	if img, ok := platform.clipboard_image_decode("image/png", identity.ICONS[LOGO_ICON].png, context.temp_allocator); ok {
		app.setup_logo = render.create_texture_rgba(&app.shared.r, img.size.x, img.size.y)
		render.update_texture_rgba(&app.shared.r, app.setup_logo, 0, 0, img.size.x, img.size.y, img.rgba)
	}
}

// At the end of the process: what an uninstall left because this process held it goes then.
setup_finish :: proc(app: ^App) {
	setup.finish(&app.setup, setup_config())
	setup.destroy(&app.setup)
	if app.setup_logo != {} { render.destroy_texture(&app.shared.r, app.setup_logo) }
}

// `inspecteur install`, `uninstall`, `status`.
cmd_install :: proc() -> int {
	ok, msg := setup.install(setup_config(), false)
	if !ok { fmt.eprintfln("inspecteur: the install failed: %s", msg); return 1 }
	fmt.printfln("inspecteur: installed: %s", msg)
	if desktop.is_nixos() { fmt.println(NIXOS_ADVICE) }
	return 0
}

cmd_uninstall :: proc() -> int {
	cfg := setup_config()
	ok, leftovers, msg := setup.uninstall(cfg)
	defer delete(leftovers)
	if ok && len(leftovers) > 0 && !setup.remove_later(cfg, leftovers[:]) { ok, msg = false, "the removal of the program cannot be scheduled" }
	if !ok { fmt.eprintfln("inspecteur: the uninstall failed: %s", msg); return 1 }
	fmt.println("inspecteur: uninstalled (the preferences stay)")
	return 0
}

cmd_status :: proc() -> int {
	f := setup.facts(setup_config())
	switch f.state {
	case .Nix_Package:       fmt.println("inspecteur: the Nix package's copy: Nix installs and updates it"); return 0
	case .This_Copy:         fmt.printfln("inspecteur: installed (%s), this copy", f.exe); return 0
	case .Other_Copy:        fmt.printfln("inspecteur: installed (%s, %s); this copy runs on its own", f.exe, f.version); return 0
	case .Repair:            fmt.printfln("inspecteur: installed (%s) with parts missing: inspecteur install repairs it", f.exe); return 2
	case .Removal_Scheduled: fmt.println("inspecteur: uninstalled; this copy goes when it ends"); return 1
	case .Not_Installed:     fmt.println("inspecteur: not installed: inspecteur install"); return 1
	}
	return 1
}

// On NixOS the Nix package is the better install: Nix updates it.
NIXOS_ADVICE :: "On NixOS the Nix package is the better install: nix profile add git+https://github.com/sachahjkl/inspecteur?submodules=1, or add it to your configuration. A classic install builds the libraries it needs with nix-build."
