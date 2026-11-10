package inspecteurtool

// bench: how fast a release build starts and how little it costs at rest, in a sway nobody sees (session.odin) that
// draws with the GPU (its Vulkan renderer), as a desktop does: inspecteur then draws on the GPU too. (On sway's CPU
// renderer, live's, it would draw with Mesa's software Vulkan: other numbers.)
//
//   inspecteurtool bench [seconds]     (default 10: the time its CPU use is measured over)
//
// - Cold start: from just before the process is started to the end of its first frame (inspecteur --first-frame says
//   when), its processes read and shown. Three starts, each in a new sway.
// - At rest: the window shown, nobody touching it, the table read again each second: the CPU time of the process over
//   `seconds`, as a share of one core, its builds, its resident memory at the end, the threads that used the CPU, and
//   what it measured of itself (a sample, a frame). Then the same with the Services and the Connections sections
//   shown: they read on threads of their own while they are on the screen.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import cdp "gt:cdp"

BENCH_DIR    :: "build/bench"
BENCH_PORT   :: 9372
BENCH_STARTS :: 3
BENCH_SETTLE :: 2 * time.Second   // after the first frame, before the CPU is measured
CLOCK_TICKS  :: 100               // USER_HZ: the unit of /proc/<pid>/stat's times

run_bench :: proc(args: []string) -> int {
	seconds := 10
	if len(args) > 0 { seconds = strconv.parse_int(args[0], 10) or_else seconds }
	if run_build({"release"}) != 0 { return 1 }
	starts: [BENCH_STARTS]f64
	for k in 0 ..< BENCH_STARTS {
		s: Session
		if why := session_start(&s, BENCH_DIR, BENCH_PORT, {"--first-frame"}, renderer = "vulkan"); why != "" {
			fmt.eprintfln("inspecteurtool bench: %s", why)
			session_stop(&s)
			return 1
		}
		ms, detail, ok := first_frame_ms(&s)
		if !ok {
			fmt.eprintfln("inspecteurtool bench: no first frame (%s)", s.output)
			session_stop(&s)
			return 1
		}
		starts[k] = ms
		fmt.printfln("start %d: first frame after %.1f ms (in the process, ms: %s)", k + 1, ms, detail)
		output := strings.clone(s.output, context.temp_allocator)
		if k == BENCH_STARTS - 1 {
			rest(&s, seconds, "at rest")
			// (the sections that read on threads of their own, shown: what they cost while they are on the screen)
			for section in ([]struct { key, name: string }{{"ctrl+3", "Services"}, {"ctrl+5", "Connections"}}) {
				if show(&s, section.key) { rest(&s, seconds, fmt.tprintf("%s shown", section.name)) }
			}
		}
		session_stop(&s)
		if k == BENCH_STARTS - 1 {
			// (what the program measured of itself, written as it ended)
			data, _ := os.read_entire_file(output, context.temp_allocator)
			if i := strings.index(string(data), "costs: "); i >= 0 { fmt.println(strings.trim_space(strings.split_lines(string(data)[i:], context.temp_allocator)[0])) }
		}
	}
	slice.sort(starts[:])
	fmt.printfln("cold start: %.1f ms (median of %d; %.1f to %.1f)", starts[BENCH_STARTS / 2], BENCH_STARTS, starts[0], starts[BENCH_STARTS - 1])
	_ = os.remove_all(BENCH_DIR)
	return 0
}

// The milliseconds from the start of the process to its first frame (its line "first-frame <unix ns>").
@(private = "file")
first_frame_ms :: proc(s: ^Session) -> (ms: f64, detail: string, ok: bool) {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		data, _ := os.read_entire_file(s.output, context.temp_allocator)
		text := string(data)
		if i := strings.index(text, "first-frame "); i >= 0 {
			line := text[i + len("first-frame "):]
			if j := strings.index_byte(line, '\n'); j >= 0 {
				line = line[:j]
				end := strings.index_byte(line, ' ')
				if end < 0 { end = len(line) }
				ns, parsed := strconv.parse_i64(line[:end], 10)
				if !parsed { return }
				return f64(ns - s.started._nsec) / 1e6, strings.trim_space(line[end:]), true
			}
		}
		time.sleep(10 * time.Millisecond)
	}
	return
}

// Presses `key` in the window (a section's shortcut).
@(private = "file")
show :: proc(s: ^Session, key: string) -> bool {
	c, ok := window_connect(s)
	if !ok { return false }
	defer cdp.close(&c)
	return cdp.key(&c, key)
}

// The CPU use of the window over `seconds`, nobody touching it, and its memory. `what`: what the window shows.
@(private = "file")
rest :: proc(s: ^Session, seconds: int, what: string) {
	time.sleep(BENCH_SETTLE)
	pid := s.program.pid
	b0 := builds(s)
	t0, _ := ticks_of(pid)
	threads0 := thread_ticks(pid)
	time.sleep(time.Duration(seconds) * time.Second)
	t1, rss := ticks_of(pid)
	threads1 := thread_ticks(pid)
	b1 := builds(s)
	share := 100 * f64(t1 - t0) / CLOCK_TICKS / f64(seconds)
	fmt.printfln("%s: %.2f%% of one core over %d s (%d ticks), %d builds, %.1f MB resident", what, share, seconds, t1 - t0, b1 - b0 - 1, f64(rss) / (1024 * 1024))
	// where it went: each thread that used some
	for tid, after in threads1 {
		d := after.ticks - (threads0[tid].ticks if tid in threads0 else 0)
		if d > 0 { fmt.printfln("  thread %d %s: %d ticks", tid, after.name, d) }
	}
}

@(private = "file")
Thread_Ticks :: struct { name: string, ticks: u64 }

// Each thread of a process: its name and its CPU ticks.
@(private = "file")
thread_ticks :: proc(pid: int) -> map[int]Thread_Ticks {
	out := make(map[int]Thread_Ticks, 16, context.temp_allocator)
	tasks, err := os.read_all_directory_by_path(fmt.tprintf("/proc/%d/task", pid), context.temp_allocator)
	if err != nil { return out }
	for t in tasks {
		tid := strconv.parse_int(t.name, 10) or_else 0
		ticks, _ := ticks_of(pid, tid)
		name, _ := os.read_entire_file(fmt.tprintf("/proc/%d/task/%d/comm", pid, tid), context.temp_allocator)
		out[tid] = {strings.trim_space(string(name)), ticks}
	}
	return out
}

// The window's count of builds (Toolkit.state; the question itself makes one).
@(private = "file")
builds :: proc(s: ^Session) -> int {
	c, ok := window_connect(s)
	if !ok { return 0 }
	defer cdp.close(&c)
	r, rok := cdp.call(&c, "Toolkit.state")
	if !rok { return 0 }
	n, _ := cdp.integer((r.(json.Object) or_else nil)["build"])
	return n
}

// user + system CPU ticks and resident bytes of a process (of one of its threads: tid).
@(private = "file")
ticks_of :: proc(pid: int, tid := 0) -> (ticks: u64, rss: u64) {
	path := tid > 0 ? fmt.tprintf("/proc/%d/task/%d/stat", pid, tid) : fmt.tprintf("/proc/%d/stat", pid)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	text := string(data)
	rest := text[strings.last_index_byte(text, ')') + 1:]
	field := 3
	for word in strings.fields_iterator(&rest) {
		switch field {
		case 14, 15: ticks += u64(strconv.parse_uint(word, 10) or_else 0)
		case 24:
			rss = u64(strconv.parse_uint(word, 10) or_else 0) * 4096
			return
		}
		field += 1
	}
	return
}
