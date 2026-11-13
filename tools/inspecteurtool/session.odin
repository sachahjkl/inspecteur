package inspecteurtool

// A session nobody sees, for `live`, `shots` and `bench`: the toolkit's sway with no screen (toolbox.sway_start: its
// own runtime directory and sockets, no session bus), and inspecteur started in it with its own configuration, data and
// state folders (its preferences, its desktop entry when a test installs it), no session bus (but for live's services,
// see session_start) and the DevTools server on a port. The person's desktop is not touched. (/proc is the machine's:
// inspecteur lists every process, and only reads them; the tests signal only the processes they start.) The install's
// dialog is not offered unless a test asks for it.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import cdp "gt:cdp"
import toolbox "gt:toolbox"

SESSION_WAIT :: 8 * time.Second
// The first connection to the window: on a CI runner a debug build drawn by lavapipe, with fontconfig making its cache,
// takes longer than any later step, so it gets its own limit.
WINDOW_START_WAIT :: 60 * time.Second
// A row that a section's reader brings (a service over D-Bus, a socket found by a scan of every process): on a slow
// runner a reading can take longer than SESSION_WAIT.
READER_WAIT :: 30 * time.Second
SESSION_POLL :: 50 * time.Millisecond
// (inspecteur floats at a size of its own, as on a desktop: the pictures have its real proportions)
SWAY_CONFIG :: "for_window [app_id=\"inspecteur\"] floating enable, resize set 1180 740, move position center\n"

Session :: struct {
	sway:    toolbox.Sway,
	dir:     string,       // the sway's folder (absolute): run/, config/, the logs
	port:    int,          // the window's DevTools port
	env:     []string,     // what inspecteur gets over the session's (owned)
	program: os.Process,
	output:  string,       // inspecteur's standard output and error (a file; owned)
	started: time.Time,    // just before inspecteur was started
	command: []string,     // inspecteur's command line (program_restart; owned)
}

// Starts sway and inspecteur in `dir` (made anew) with `args`. `renderer`: sway's (pixman: the CPU, anywhere; vulkan: the
// GPU, as on a desktop: inspecteur then draws on the GPU too). `user_bus`: inspecteur gets the person's session bus,
// for its Services and Startup sections to reach the user's service manager (live: it acts only on a transient unit it
// made itself). `setup`: the install's dialog is offered at the start. `own_cache`: its XDG_CACHE_HOME is the session's.
// `before`: writes what inspecteur reads at its start in the session's folders (live: a desktop entry of its own).
// `why` says what failed.
session_start :: proc(s: ^Session, dir: string, port: int, args: []string = nil, renderer := "pixman", user_bus := false, setup := false, own_cache := false, before: proc(dir: string) = nil) -> (why: string) {
	// (a Ctrl+C or a timeout's signal stops sway and inspecteur with the tool)
	toolbox.guard_groups()
	s.port = port
	why = toolbox.sway_start(&s.sway, dir, {config = SWAY_CONFIG, renderer = renderer, homes = true, cache = own_cache})
	s.dir = s.sway.dir
	if why != "" { return }
	prefs_dir := fmt.tprintf("%s/config/inspecteur", s.dir)
	if err := os.make_directory_all(prefs_dir); err != nil && err != .Exist { return fmt.tprintf("%s cannot be made", prefs_dir) }
	if before != nil { before(s.dir) }   // (what the test puts in the session's folders before inspecteur reads them)

	extra := make([dynamic]string, context.temp_allocator)
	append(&extra, fmt.tprintf("TOOLKIT_DEVTOOLS=%d", port))
	if bus := user_bus_address(); user_bus && bus != "" { append(&extra, fmt.tprintf("DBUS_SESSION_BUS_ADDRESS=%s", bus)) }
	s.env = make([]string, len(extra))
	for e, i in extra { s.env[i] = strings.clone(e) }
	s.output = strings.clone(fmt.tprintf("%s/inspecteur.log", s.dir))
	command := make([dynamic]string, context.temp_allocator)
	append(&command, PROGRAM)
	if !setup { append(&command, "--pref", "setup.choice=standalone") }
	// (a finished act is said in the window: a notification of the system would reach the person's desktop)
	append(&command, "--pref", "general.messages=window")
	// (English whatever the person's locale: live reads the window's English texts, the pictures are of the English)
	append(&command, "--pref", "general.language=en")
	append(&command, ..args)
	s.command = make([]string, len(command))
	for a, i in command { s.command[i] = strings.clone(a) }
	s.started = time.now()
	s.program, why = toolbox.sway_program(&s.sway, s.command, s.env, s.output)
	return
}

// Closes inspecteur's window (it ends as the person's would) and starts it again in the same session and folders: what
// it kept is read again. `c` is then the new window's connection. False: it did not end with 0, or did not come back.
// (The new run's output replaces the first's in s.output.)
program_restart :: proc(s: ^Session, c: ^cdp.Client) -> bool {
	_ = cdp.send(c, "Browser.close")
	cdp.close(c)
	state, ended := toolbox.sway_wait(&s.sway, s.program, SESSION_WAIT)
	s.program = {}
	// (one that did not end is stopped with the session)
	if !ended || !state.exited || state.exit_code != 0 { return false }
	p, why := toolbox.sway_program(&s.sway, s.command, s.env, s.output)
	if why != "" { return false }
	s.program = p
	ok: bool
	c^, ok = window_connect(s)
	return ok
}

// The person's session bus: DBUS_SESSION_BUS_ADDRESS, else the socket of the user's service manager,
// $XDG_RUNTIME_DIR/bus (a CI runner has the manager and not the variable); "" when there is neither.
user_bus_address :: proc() -> string {
	if bus := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator); bus != "" { return bus }
	runtime := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if runtime != "" && os.exists(fmt.tprintf("%s/bus", runtime)) { return fmt.tprintf("unix:path=%s/bus", runtime) }
	return ""
}

// Ends inspecteur (its window closed over the protocol; stopped with the session after SESSION_WAIT) and sway.
// `exit_code` is inspecteur's (-1: it was stopped).
session_stop :: proc(s: ^Session) -> (exit_code: int) {
	exit_code = -1
	if s.program.handle != 0 {
		if c, ok := cdp.connect(s.port); ok {
			c.quiet = true
			_ = cdp.send(&c, "Browser.close")
			cdp.close(&c)
		}
		if state, ended := toolbox.sway_wait(&s.sway, s.program, SESSION_WAIT); ended && state.exited { exit_code = state.exit_code }
		s.program = {}
	}
	toolbox.sway_stop(&s.sway)
	for e in s.env { delete(e) }
	delete(s.env)
	for a in s.command { delete(a) }
	delete(s.command)
	delete(s.output)
	s^ = {}
	return
}

// A connection to the window's DevTools server, tried until WINDOW_START_WAIT.
window_connect :: proc(s: ^Session) -> (c: cdp.Client, ok: bool) {
	deadline := time.tick_add(time.tick_now(), WINDOW_START_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if c, ok = cdp.connect(s.port); ok { return }
		time.sleep(SESSION_POLL)
	}
	return
}
