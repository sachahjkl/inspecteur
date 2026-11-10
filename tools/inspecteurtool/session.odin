package inspecteurtool

// A session nobody sees, for `live`, `shots` and `bench`: a sway with no screen (headless, pixman) in a runtime
// directory of its own, and inspecteur started in it with its own configuration and data folders (its preferences, its
// desktop entry when a test installs it), no session bus (but for live's services, see session_start) and the DevTools
// server on a port. The person's desktop is not touched. (/proc is the machine's: inspecteur lists every process, and
// only reads them; the tests signal only the processes they start.) The welcome page is off unless a test asks for it.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import cdp "gt:cdp"
import toolbox "gt:toolbox"

SESSION_WAIT :: 8 * time.Second
SESSION_POLL :: 50 * time.Millisecond
// (inspecteur floats at a size of its own, as on a desktop: the pictures have its real proportions)
SWAY_CONFIG :: "output HEADLESS-1 resolution 1600x1000\nxwayland disable\nfor_window [app_id=\"inspecteur\"] floating enable, resize set 1180 740, move position center\n"

Session :: struct {
	dir:     string,     // absolute: run/, config/, the logs
	port:    int,        // the window's DevTools port
	env:     []string,   // inspecteur's
	sway:    os.Process,
	program: os.Process,
	up:      bool,       // sway runs (session_stop stops it)
	output:  string,     // inspecteur's standard output and error (a file)
	started: time.Time,  // just before inspecteur was started
}

// Starts sway and inspecteur in `dir` (made anew) with `args`. `renderer`: sway's (pixman: the CPU, anywhere; vulkan: the
// GPU, as on a desktop: inspecteur then draws on the GPU too). `user_bus`: inspecteur gets the person's session bus,
// for its Services and Startup sections to reach the user's service manager (live: it acts only on a transient unit it
// made itself). `welcome`: the welcome page shows at the start. `before`: writes what inspecteur reads at its start in
// the session's folders (live: a desktop entry of its own). `why` says what failed.
session_start :: proc(s: ^Session, dir: string, port: int, args: []string = nil, renderer := "pixman", user_bus := false, welcome := false, before: proc(dir: string) = nil) -> (why: string) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	s.dir = strings.clone(fmt.tprintf("%s/%s", cwd, dir))
	s.port = port
	_ = os.remove_all(s.dir)
	run := fmt.tprintf("%s/run", s.dir)
	for d in ([]string{run, fmt.tprintf("%s/config/inspecteur", s.dir), fmt.tprintf("%s/data", s.dir)}) {
		if os.make_directory_all(d) != nil { return fmt.tprintf("%s cannot be made", d) }
	}
	_ = os.chmod(run, {.Read_User, .Write_User, .Execute_User})   // (a runtime directory is the user's alone)
	if before != nil { before(s.dir) }   // (what the test puts in the session's folders before inspecteur reads them)
	conf := fmt.tprintf("%s/sway.conf", s.dir)
	_ = os.write_entire_file(conf, SWAY_CONFIG)

	sway_env := toolbox.env_with({"WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "SWAYSOCK"},
		fmt.tprintf("XDG_RUNTIME_DIR=%s", run), "WLR_BACKENDS=headless", fmt.tprintf("WLR_RENDERER=%s", renderer), "WLR_LIBINPUT_NO_DEVICES=1")
	log, lerr := os.open(fmt.tprintf("%s/sway.log", s.dir), {.Write, .Create, .Trunc})
	if lerr != nil { return "the log cannot be written" }
	// (a group of its own: NixOS's sway is a wrapper, and its real sway and swaybg must end with it)
	sway, serr := toolbox.start_group({"sway", "--unsupported-gpu", "-c", conf}, sway_env, log)
	os.close(log)
	if serr != nil { return "sway does not start (is it on the PATH? nix develop has it)" }
	s.sway, s.up = sway, true
	socket := ""
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for socket == "" && time.tick_diff(time.tick_now(), deadline) > 0 {
		if fis, err := os.read_all_directory_by_path(run, context.temp_allocator); err == nil {
			for fi in fis { if strings.has_prefix(fi.name, "wayland-") && !strings.has_suffix(fi.name, ".lock") { socket = strings.clone(fi.name, context.temp_allocator) } }
		}
		if socket == "" { time.sleep(SESSION_POLL) }
	}
	if socket == "" { return fmt.tprintf("sway made no Wayland socket (%s/sway.log)", s.dir) }

	env := toolbox.env_with({"WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"},
		fmt.tprintf("XDG_RUNTIME_DIR=%s", run), fmt.tprintf("WAYLAND_DISPLAY=%s", socket),
		fmt.tprintf("XDG_CONFIG_HOME=%s/config", s.dir), fmt.tprintf("XDG_STATE_HOME=%s/state", s.dir),
		fmt.tprintf("XDG_DATA_HOME=%s/data", s.dir), fmt.tprintf("TOOLKIT_DEVTOOLS=%d", port))
	bus := user_bus_address()
	s.env = make([]string, len(env) + (user_bus && bus != "" ? 1 : 0))
	for e, i in env { s.env[i] = strings.clone(e) }
	if user_bus && bus != "" { s.env[len(env)] = strings.clone(fmt.tprintf("DBUS_SESSION_BUS_ADDRESS=%s", bus)) }
	s.output = strings.clone(fmt.tprintf("%s/inspecteur.log", s.dir))
	out, oerr := os.open(s.output, {.Write, .Create, .Trunc})
	if oerr != nil { return "the log cannot be written" }
	command := make([dynamic]string, context.temp_allocator)
	append(&command, PROGRAM)
	if !welcome { append(&command, "--pref", "setup.welcome=false") }
	append(&command, ..args)
	s.started = time.now()
	p, err := os.process_start({command = command[:], env = s.env, stdout = out, stderr = out})
	os.close(out)
	if err != nil { return fmt.tprintf("%s does not start", PROGRAM) }
	s.program = p
	return ""
}

// The person's session bus: DBUS_SESSION_BUS_ADDRESS, else the socket of the user's service manager,
// $XDG_RUNTIME_DIR/bus (a CI runner has the manager and not the variable); "" when there is neither.
user_bus_address :: proc() -> string {
	if bus := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator); bus != "" { return bus }
	runtime := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if runtime != "" && os.exists(fmt.tprintf("%s/bus", runtime)) { return fmt.tprintf("unix:path=%s/bus", runtime) }
	return ""
}

// Ends inspecteur (its window closed over the protocol, killed after SESSION_WAIT) and sway. `exit_code` is
// inspecteur's (-1: it was killed).
session_stop :: proc(s: ^Session) -> (exit_code: int) {
	exit_code = -1
	if s.program.handle != 0 {
		if c, ok := cdp.connect(s.port); ok {
			c.quiet = true
			_ = cdp.send(&c, "Browser.close")
			cdp.close(&c)
		}
		if state, err := os.process_wait(s.program, SESSION_WAIT); err == nil && state.exited {
			exit_code = state.exit_code
		} else {
			_ = os.process_kill(s.program)   // (the process this session started)
			_, _ = os.process_wait(s.program, SESSION_WAIT)
		}
		s.program = {}
	}
	if s.up {
		toolbox.stop_group(s.sway)
		s.up = false
	}
	for e in s.env { delete(e) }
	delete(s.env)
	delete(s.dir)
	delete(s.output)
	return
}

// A connection to the window's DevTools server, tried until SESSION_WAIT.
window_connect :: proc(s: ^Session) -> (c: cdp.Client, ok: bool) {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if c, ok = cdp.connect(s.port); ok { return }
		time.sleep(SESSION_POLL)
	}
	return
}
