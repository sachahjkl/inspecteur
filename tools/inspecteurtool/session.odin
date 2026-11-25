#+build linux
package inspecteurtool

// A session nobody sees, for `live`, `shots` and `bench`: the toolkit's program session (toolbox.Program_Session: its
// sway with no screen, its own runtime directory and sockets, no session bus, the DevTools server on a free port), and
// inspecteur started in it with its own configuration, data and state folders (its preferences, its desktop entry when
// a test installs it), no session bus (but for live's services, see session_start). The person's desktop is not
// touched. (/proc is the machine's: inspecteur lists every process, and only reads them; the tests signal only the
// processes they start.) The install's dialog is not offered unless a test asks for it.

import "core:fmt"
import "core:os"
import "core:time"
import toolbox "gt:toolbox"

SESSION_WAIT :: 8 * time.Second
// A row that a section's reader brings (a service over D-Bus, a socket found by a scan of every process): on a slow
// runner a reading can take longer than SESSION_WAIT.
READER_WAIT :: 30 * time.Second
// The step of the tests' own polls (a file, a process's state): what no window's wait can see.
SESSION_POLL :: 50 * time.Millisecond
// (inspecteur floats at a size of its own, as on a desktop: the pictures have its real proportions)
SWAY_CONFIG :: "for_window [app_id=\"inspecteur\"] floating enable, resize set 1180 740, move position center\n"

// Starts sway and inspecteur in `dir` (made anew) with `args`. `renderer`: sway's (pixman: the CPU, anywhere; vulkan: the
// GPU, as on a desktop: inspecteur then draws on the GPU too). `user_bus`: inspecteur gets the person's session bus,
// for its Services and Startup sections to reach the user's service manager (live: it acts only on a transient unit it
// made itself). `setup`: the install's dialog is offered at the start. `own_cache`: its XDG_CACHE_HOME is the session's.
// `files`: what inspecteur reads at its start, written in the session's folders (live: desktop entries of its own).
// `why` says what failed (toolbox.program_session_stop still cleans up).
session_start :: proc(s: ^toolbox.Program_Session, dir: string, args: []string = nil, renderer := "pixman", user_bus := false, setup := false, own_cache := false, files: []toolbox.Program_File = nil) -> (why: string) {
	env := make([dynamic]string, context.temp_allocator)
	if bus := user_bus_address(); user_bus && bus != "" { append(&env, fmt.tprintf("DBUS_SESSION_BUS_ADDRESS=%s", bus)) }
	command := make([dynamic]string, context.temp_allocator)
	append(&command, PROGRAM)
	if !setup { append(&command, "--pref", "install.choice=standalone") }
	// (a finished act is said in the window: a notification of the system would reach the person's desktop)
	append(&command, "--pref", "general.messages=window")
	// (English whatever the person's locale: live reads the window's English texts, the pictures are of the English)
	append(&command, "--pref", "general.language=en")
	append(&command, ..args)
	// (its output goes to the session's inspecteur.log: the session's default for build/inspecteur)
	return toolbox.program_session_start(s, dir, {
		command = command[:], env = env[:], files = files,
		desktop = {config = SWAY_CONFIG, renderer = renderer, homes = true, cache = own_cache},
	})
}

// The person's session bus: DBUS_SESSION_BUS_ADDRESS, else the socket of the user's service manager,
// $XDG_RUNTIME_DIR/bus (a CI runner has the manager and not the variable); "" when there is neither.
user_bus_address :: proc() -> string {
	if bus := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator); bus != "" { return bus }
	runtime := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if runtime != "" && os.exists(fmt.tprintf("%s/bus", runtime)) { return fmt.tprintf("unix:path=%s/bus", runtime) }
	return ""
}
