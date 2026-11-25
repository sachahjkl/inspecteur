#+build linux
package inspecteur

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "core:sys/linux"

@(private = "file")
thread_cpu_ns :: proc() -> i64 {
	ts, err := linux.clock_gettime(.THREAD_CPUTIME_ID)
	if err != .NONE { return 0 }
	return i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec)
}

@(private = "file")
median_f64 :: proc(vals: []f64) -> f64 {
	if len(vals) == 0 { return 0 }
	cp := slice.clone(vals, context.temp_allocator)
	slice.sort(cp)
	return cp[len(cp) / 2]
}

@(private = "file")
proc_stats_total :: proc(s: Proc_Read_Stats, include_fstats := true) -> int {
	return s.opens + s.reads + s.preads + s.closes + s.getdents + s.epoll_waits + s.pidfds + (include_fstats ? s.fstats : 0)
}

// Opt-in regression benchmark for the Linux readers and neutral pipeline:
//   inspecteurtool bench_reader
//   INSPECTEUR_BENCH=1 odin test src ... -define:ODIN_TEST_NAMES=inspecteur.bench_readers_and_neutral -o:speed
@(test)
bench_readers_and_neutral :: proc(t: ^testing.T) {
	if os.get_env("INSPECTEUR_BENCH", context.temp_allocator) == "" { return }

	RUNS :: 11
	fmt.printfln("\n=== REAL SYSTEM READERS (median of %d runs) ===", RUNS)

	pr: Proc_Reader
	testing.expect(t, proc_reader_init(&pr))
	defer proc_reader_destroy(&pr)

	wall, cpu: [RUNS]f64
	out := make([dynamic]Proc_Counters, 0, 1024)
	defer delete(out)

	// Cold first sample (discovers kthreads, opens kept user descriptors, populates io_denied)
	{
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		procs_read(&pr, &out)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		io_known_n := 0
		for c in out { if c.io_known { io_known_n += 1 } }
		fmt.printfln("Real /proc: total_pids=%d user_procs=%d kthreads=%d io_known=%d io_denied=%d kept_fds=%d/%d",
			len(pr.pids), len(out), len(pr.pids) - len(out), io_known_n, len(pr.io_denied), pr.kept_fds, pr.fd_budget)
		fmt.printfln("procs_read (cold 1st):   wall=%.3f ms  cpu=%.3f ms  syscalls=%d (open=%d read=%d pread=%d close=%d getdents=%d pidfd=%d epoll=%d)",
			time.duration_milliseconds(time.tick_diff(t0, t1)), f64(c1 - c0) / 1e6, proc_stats_total(pr.stats),
			pr.stats.opens, pr.stats.reads, pr.stats.preads, pr.stats.closes, pr.stats.getdents, pr.stats.pidfds, pr.stats.epoll_waits)
	}

	temp_track, heap_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&heap_track, context.allocator)
	defer mem.tracking_allocator_destroy(&heap_track)
	mem.tracking_allocator_init(&temp_track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&temp_track)

	for i in 0 ..< RUNS {
		free_all(context.temp_allocator)
		clear(&out)
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		procs_read(&pr, &out)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[i] = f64(c1 - c0) / 1e6
	}
	{
		free_all(context.temp_allocator)
		clear(&out)
		old_a, old_ta := context.allocator, context.temp_allocator
		context.allocator = mem.tracking_allocator(&heap_track)
		context.temp_allocator = mem.tracking_allocator(&temp_track)
		procs_read(&pr, &out)
		context.allocator, context.temp_allocator = old_a, old_ta
	}
	fmt.printfln("procs_read (steady):     wall=%.3f ms  cpu=%.3f ms  syscalls=%d (open=%d read=%d pread=%d close=%d getdents=%d epoll=%d)  heap=%d (%d B)  temp=%d (%d B)",
		median_f64(wall[:]), median_f64(cpu[:]), proc_stats_total(pr.stats),
		pr.stats.opens, pr.stats.reads, pr.stats.preads, pr.stats.closes, pr.stats.getdents, pr.stats.epoll_waits,
		heap_track.total_allocation_count, heap_track.total_memory_allocated,
		temp_track.total_allocation_count, temp_track.total_memory_allocated)

	// The plain reader (the algorithm before the kept descriptors), on the same processes
	plain := make([dynamic]Proc_Counters, 0, 1024)
	defer delete(plain)
	plain_calls := 0
	for i in 0 ..< RUNS {
		free_all(context.temp_allocator)
		clear(&plain)
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		plain_calls = plain_procs_read("/proc", pr.page_bytes, &plain)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[i] = f64(c1 - c0) / 1e6
	}
	fmt.printfln("plain reader:            wall=%.3f ms  cpu=%.3f ms  syscalls=%d", median_f64(wall[:]), median_f64(cpu[:]), plain_calls)

	// proc_facts on all live user processes (cold startup cost)
	for i in 0 ..< RUNS {
		free_all(context.temp_allocator)
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		for c in out { _ = proc_facts(&pr, c) }
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[i] = f64(c1 - c0) / 1e6
	}
	fmt.printfln("proc_facts (all %d):    wall=%.3f ms  cpu=%.3f ms", len(out), median_f64(wall[:]), median_f64(cpu[:]))

	// machine_read
	mr: Machine_Reader
	machine_reader_init(&mr)
	defer machine_reader_destroy(&mr)
	mc: Machine_Counters
	machine_read(&mr, &mc) // warmup (opens kept fds + lists hwmon)
	fmt.printfln("Machine sensors: temp_n=%d core_file_n=%d pm_cores=%d has_pressure=%v no_throttle=%v",
		mr.temp_n, mr.core_file_n, mr.pm.cores, mc.has_pressure, mr.no_throttle)

	{
		mem.tracking_allocator_clear(&heap_track)
		mem.tracking_allocator_clear(&temp_track)
		heap_track.total_allocation_count, heap_track.total_memory_allocated = 0, 0
		temp_track.total_allocation_count, temp_track.total_memory_allocated = 0, 0
		for i in 0 ..< RUNS {
			free_all(context.temp_allocator)
			mc = {}
			t0 := time.tick_now()
			c0 := thread_cpu_ns()
			machine_read(&mr, &mc)
			c1 := thread_cpu_ns()
			t1 := time.tick_now()
			wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
			cpu[i] = f64(c1 - c0) / 1e6
		}
		{
			free_all(context.temp_allocator)
			mc = {}
			old_a, old_ta := context.allocator, context.temp_allocator
			context.allocator = mem.tracking_allocator(&heap_track)
			context.temp_allocator = mem.tracking_allocator(&temp_track)
			machine_read(&mr, &mc)
			context.allocator, context.temp_allocator = old_a, old_ta
		}
		fmt.printfln("machine_read:            wall=%.3f ms  cpu=%.3f ms  heap=%d (%d B)  temp=%d (%d B)",
			median_f64(wall[:]), median_f64(cpu[:]),
			heap_track.total_allocation_count, heap_track.total_memory_allocated,
			temp_track.total_allocation_count, temp_track.total_memory_allocated)
	}

	// disks_list + nets_list (run every 10 samples)
	for i in 0 ..< RUNS {
		free_all(context.temp_allocator)
		d := make([dynamic]Disk_Info, context.temp_allocator)
		n := make([dynamic]Net_Info, context.temp_allocator)
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		disks_list(&d)
		nets_list(&n)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[i] = f64(c1 - c0) / 1e6
	}
	fmt.printfln("disks_list + nets_list:  wall=%.3f ms  cpu=%.3f ms", median_f64(wall[:]), median_f64(cpu[:]))

	// sockets_read: full scan, incremental (1 unknown owned inode), cached
	sr: Socket_Reader
	defer socket_reader_destroy(&sr)
	socks := make([dynamic]Socket)
	defer delete(socks)
	for i in 0 ..< 5 {
		free_all(context.temp_allocator)
		clear(&socks)
		sr.skipped = OWNER_SCAN_EVERY
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		sockets_read(&sr, &socks)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[i] = f64(c1 - c0) / 1e6
	}
	fmt.printfln("sockets_read (full %d): wall=%.3f ms  cpu=%.3f ms  owners=%d", len(socks), median_f64(wall[:5]), median_f64(cpu[:5]), len(sr.owners))

	// Pick one real owned inode to measure incremental single-inode lookup
	sample_inode: u64
	for ino in sr.owners { sample_inode = ino; break }
	if sample_inode != 0 {
		for i in 0 ..< 5 {
			free_all(context.temp_allocator)
			clear(&socks)
			delete_key(&sr.owners, sample_inode)
			delete_key(&sr.unowned, sample_inode)
			sr.skipped = 0
			t0 := time.tick_now()
			c0 := thread_cpu_ns()
			sockets_read(&sr, &socks)
			c1 := thread_cpu_ns()
			t1 := time.tick_now()
			wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
			cpu[i] = f64(c1 - c0) / 1e6
		}
		fmt.printfln("sockets_read (incr 1):   wall=%.3f ms  cpu=%.3f ms", median_f64(wall[:5]), median_f64(cpu[:5]))
	}

	for i in 0 ..< RUNS {
		free_all(context.temp_allocator)
		clear(&socks)
		sr.skipped = 0
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		sockets_read(&sr, &socks)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[i] = f64(c1 - c0) / 1e6
	}
	fmt.printfln("sockets_read (cached):   wall=%.3f ms  cpu=%.3f ms", median_f64(wall[:]), median_f64(cpu[:]))

	// gpu_read: with and without what each process uses. Opt-in: it opens the driver's library (NVML)
	if os.get_env("INSPECTEUR_BENCH_GPU", context.temp_allocator) != "" {
	gr: Gpu_Reader
	defer gpu_reader_close(&gr)
	snap: Gpu_Snapshot
	gpu_read(&gr, &snap, false) // warmup
	for procs in ([2]bool{true, false}) {
		for i in 0 ..< 5 {
			free_all(context.temp_allocator)
			snap = {want_procs = procs}
			t0 := time.tick_now()
			c0 := thread_cpu_ns()
			gpu_read(&gr, &snap, false)
			c1 := thread_cpu_ns()
			t1 := time.tick_now()
			wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
			cpu[i] = f64(c1 - c0) / 1e6
		}
		fmt.printfln("gpu_read (want_procs=%-5v): wall=%.3f ms  cpu=%.3f ms  gpus=%d procs=%d",
			procs, median_f64(wall[:5]), median_f64(cpu[:5]), snap.count, snap.proc_count)
	}
	}

	// Neutral pipeline on 5,000 synthetic processes
	fmt.printfln("\n=== NEUTRAL PIPELINE (5,000 synthetic processes) ===")
	N :: 5000
	cat: Catalog
	defer catalog_destroy(&cat)
	for k in 0 ..< 20 {
		catalog_add_entry(&cat, fmt.tprintf("org.app.app%d", k), fmt.tprintf("App %d", k), "", fmt.tprintf("app%d", k), "")
	}
	counters := make([]Proc_Counters, N)
	defer delete(counters)
	facts := make([]Proc_Facts, N)
	defer delete(facts)
	for i in 0 ..< N {
		pid := i32(i + 1)
		ppid := i == 0 ? i32(0) : i32(i % 50 == 0 ? 1 : (i / 50) * 50 + 1)
		app_idx := i % 50 == 0 && (i / 50) < 20 ? (i / 50) : -1
		name := app_idx >= 0 ? fmt.aprintf("app%d", app_idx) : fmt.aprintf("worker-%d", i)
		counters[i] = {
			pid = pid, ppid = ppid, start = u64(1000 + i), comm = name,
			cpu_ns = u64(i) * 1_000_000, threads = i32(1 + i % 8), state = .Sleeping,
			resident = u64(10 + i % 200) * 1024 * 1024, private = u64(5 + i % 100) * 1024 * 1024,
			io_read = u64(i) * 4096, io_write = u64(i) * 2048, io_known = true,
		}
		facts[i] = {name = name, cmdline = name, exe = "/usr/bin/worker", user = "alex", read = true}
	}
	defer for f in facts { delete(f.name) }

	s: Sampler
	defer sampler_destroy(&s)
	tb: Table
	defer table_destroy(&tb)
	table_columns_init(&tb)
	tb.layout.sort, tb.layout.descending = int(Column.CPU), true

	procs_merge(&s, counters, facts, 0, 0, &cat, true, 1_000_000_000)

	for i in 0 ..< RUNS {
		free_all(context.temp_allocator)
		for &c, k in counters { c.cpu_ns += u64(k % 17) * 100_000 }
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		procs_merge(&s, counters, nil, 1.0, 16_000_000_000, &cat, true, i64(i + 2) * 1_000_000_000)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[i] = f64(c1 - c0) / 1e6
	}
	fmt.printfln("procs_merge (5000):      wall=%.3f ms  cpu=%.3f ms", median_f64(wall[:]), median_f64(cpu[:]))

	for i in 0 ..< RUNS {
		free_all(context.temp_allocator)
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		table_group(&tb, s.procs[:])
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[i] = f64(c1 - c0) / 1e6
	}
	fmt.printfln("table_group (5000):      wall=%.3f ms  cpu=%.3f ms  groups=%d bg=%d", median_f64(wall[:]), median_f64(cpu[:]), len(tb.groups), len(tb.background))

	for i in 0 ..< RUNS {
		free_all(context.temp_allocator)
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		table_rows(&tb, &s, &cat)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[i] = f64(c1 - c0) / 1e6
	}
	fmt.printfln("table_rows apps (5000):  wall=%.3f ms  cpu=%.3f ms  rows=%d", median_f64(wall[:]), median_f64(cpu[:]), len(tb.rows))

	tb.tree = true
	for i in 0 ..< RUNS {
		free_all(context.temp_allocator)
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		table_rows(&tb, &s, &cat)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[i] = f64(c1 - c0) / 1e6
	}
	fmt.printfln("table_rows tree (5000):  wall=%.3f ms  cpu=%.3f ms  rows=%d", median_f64(wall[:]), median_f64(cpu[:]), len(tb.rows))
	tb.tree = false

	fake_app := new(App)
	defer free(fake_app)
	fake_app.sampler = s
	defer fake_app.sampler = {}
	defer ranking_destroy(&fake_app.ranking)
	for i in 0 ..< RUNS {
		free_all(context.temp_allocator)
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		ranking_make(fake_app)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[i] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[i] = f64(c1 - c0) / 1e6
	}
	fmt.printfln("ranking_make (5000):     wall=%.3f ms  cpu=%.3f ms", median_f64(wall[:]), median_f64(cpu[:]))

	// Churn memory test: 200 samples x 200 short-lived processes = 40,000 processes
	fmt.printfln("\n=== CHURN MEMORY TEST (200 samples x 200 short procs = 40,000 procs) ===")
	mem_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&mem_track, context.allocator)
	defer mem.tracking_allocator_destroy(&mem_track)
	{
		old_a := context.allocator
		context.allocator = mem.tracking_allocator(&mem_track)
		defer context.allocator = old_a

		cs: Sampler
		defer sampler_destroy(&cs)
		ct: Table
		defer table_destroy(&ct)
		table_columns_init(&ct)

		batch := make([dynamic]Proc_Counters, 0, 400)
		defer delete(batch)
		bfacts := make([dynamic]Proc_Facts, 0, 400)
		defer delete(bfacts)

		for step in 0 ..< 200 {
			free_all(context.temp_allocator)
			clear(&batch); clear(&bfacts)
			for p in 0 ..< 100 {
				append(&batch, Proc_Counters{pid = i32(p + 1), ppid = 1, start = 1, comm = "steady", cpu_ns = u64(step) * 1000, threads = 1, private = 1024 * 1024})
				append(&bfacts, Proc_Facts{name = "steady", cmdline = "steady --run", user = "alex", read = step == 0})
			}
			base_pid := i32(1000 + (step % 10) * 200)
			for p in 0 ..< 200 {
				pid := base_pid + i32(p)
				append(&batch, Proc_Counters{pid = pid, ppid = 1, start = u64(100 + step * 1000 + p), comm = "short", cpu_ns = 100, threads = 1, private = 4096})
				append(&bfacts, Proc_Facts{name = "short", cmdline = "short --tmp", user = "alex", read = true})
			}
			now_ns := i64(step + 1) * 1_000_000_000
			procs_merge(&cs, batch[:], bfacts[:], 1.0, 16_000_000_000, nil, true, now_ns)
			table_group(&ct, cs.procs[:])
			table_rows(&ct, &cs, &cat)
			if step == 10 || step == 50 || step == 199 {
				fmt.printfln("  step %3d: procs=%d  live_mem=%d KiB  peak_mem=%d KiB  total_allocs=%d",
					step, len(cs.procs), mem_track.current_memory_allocated / 1024, mem_track.peak_memory_allocated / 1024, mem_track.total_allocation_count)
			}
		}
	}
}

// Opt-in 5,000-process synthetic /proc benchmark + exactness check against plain_procs_read.
//   inspecteurtool bench_reader
@(test)
bench_synthetic_5000 :: proc(t: ^testing.T) {
	if os.get_env("INSPECTEUR_BENCH", context.temp_allocator) == "" { return }

	RUNS :: 7
	USER_N :: 4000
	KTHREAD_N :: 1000
	SYNTH_FDS :: 4 * USER_N
	root := fmt.aprintf("%s/inspecteur-bench-5000-%d", synth_dir(), os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer {
		for i in 0 ..< USER_N {
			if i % 10 == 0 { _ = os.chmod(fmt.tprintf("%s/%d/io", root, 2000 + i), {.Read_User, .Write_User}) }
		}
		_ = os.remove_all(root)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/stat", root), "cpu  100 0 50 850 0 0 0 0 0 0\nbtime 1700000000\n")

	// Build 1,000 kernel threads (pids 2..1001) + 4,000 user processes (pids 2000..5999)
	synth_write_proc(root, 2, 0, "kthreadd", 'S', PF_KTHREAD, 0, 1, 0, 1, 10, 0, 0, 0, 0, write_statm = false, write_io = false)
	for i in 1 ..< KTHREAD_N {
		synth_write_proc(root, i32(2 + i), 2, fmt.tprintf("kworker/%d:0", i % 16), 'I', PF_KTHREAD, u64(i), 0, 0, 1, u64(10 + i), 0, 0, 0, 0, write_statm = false, write_io = false)
	}
	for i in 0 ..< USER_N {
		pid := i32(2000 + i)
		comm: string
		switch i % 20 {
		case 0: comm = "Web (Content) 1"
		case 1: comm = "line\nbreak (x)"
		case:   comm = fmt.tprintf("worker-%d", i)
		}
		synth_write_proc(root, pid, i == 0 ? 1 : 2000, comm, 'S', 0, u64(i * 3), u64(i), i8(i % 20 - 10), i32(1 + i % 8),
			u64(500 + i), u64(100 + i % 500), u64(20 + i % 80), u64(i * 4096), u64(i * 1024),
			chmod_io_0 = (i % 10 == 0))
	}
	// Vanished process directory (no stat)
	_ = os.make_directory_all(fmt.tprintf("%s/99999", root))

	fmt.printfln("\n=== SYNTHETIC 5,000-PROCESS /PROC BENCHMARK (median of %d runs, %d user + %d kthreads) ===", RUNS, USER_N, KTHREAD_N)

	temp_track, heap_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&heap_track, context.allocator)
	defer mem.tracking_allocator_destroy(&heap_track)
	mem.tracking_allocator_init(&temp_track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&temp_track)

	want := make([dynamic]Proc_Counters, 0, USER_N)
	defer delete(want)
	got := make([dynamic]Proc_Counters, 0, USER_N)
	defer delete(got)
	wall, cpu: [RUNS]f64
	plain_syscalls := 0

	// 1. Plain reference reader
	for r in 0 ..< RUNS {
		free_all(context.temp_allocator)
		clear(&want)
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		plain_syscalls = plain_procs_read(root, PAGE_BYTES_USUAL, &want)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		wall[r] = time.duration_milliseconds(time.tick_diff(t0, t1))
		cpu[r] = f64(c1 - c0) / 1e6
	}
	{
		free_all(context.temp_allocator)
		clear(&want)
		old_a, old_ta := context.allocator, context.temp_allocator
		context.allocator = mem.tracking_allocator(&heap_track)
		context.temp_allocator = mem.tracking_allocator(&temp_track)
		plain_syscalls = plain_procs_read(root, PAGE_BYTES_USUAL, &want)
		context.allocator, context.temp_allocator = old_a, old_ta
	}
	testing.expect_value(t, len(want), USER_N)
	// Preserve reference comm strings across temp_allocator resets in the benchmark loops below.
	for &w in want { w.comm = strings.clone(w.comm) }
	defer for w in want { delete(w.comm) }
	fmt.printfln("plain_procs_read (5000):        wall=%.3f ms  cpu=%.3f ms  syscalls=%d  heap=%d (%d B)  temp=%d (%d B)",
		median_f64(wall[:]), median_f64(cpu[:]), plain_syscalls,
		heap_track.total_allocation_count, heap_track.total_memory_allocated,
		temp_track.total_allocation_count, temp_track.total_memory_allocated)

	// 2. Optimized Proc_Reader with every descriptor kept (a tmpfs file keeps no kernel page)
	{
		pr: Proc_Reader
		testing.expect(t, proc_reader_init_root(&pr, root, fd_budget = SYNTH_FDS))
		defer proc_reader_destroy(&pr)

		// Cold first sample + exact equality check
		clear(&got)
		t0 := time.tick_now()
		c0 := thread_cpu_ns()
		procs_read(&pr, &got)
		c1 := thread_cpu_ns()
		t1 := time.tick_now()
		expect_counters_equal(t, got[:], want[:], "synth5000 kept cold")
		fmt.printfln("procs_read kept (5000, cold):   wall=%.3f ms  cpu=%.3f ms  syscalls=%d  kept_fds=%d",
			time.duration_milliseconds(time.tick_diff(t0, t1)), f64(c1 - c0) / 1e6, proc_stats_total(pr.stats), pr.kept_fds)

		for r in 0 ..< RUNS {
			free_all(context.temp_allocator)
			clear(&got)
			t0 = time.tick_now()
			c0 = thread_cpu_ns()
			procs_read(&pr, &got)
			c1 = thread_cpu_ns()
			t1 = time.tick_now()
			wall[r] = time.duration_milliseconds(time.tick_diff(t0, t1))
			cpu[r] = f64(c1 - c0) / 1e6
		}
		expect_counters_equal(t, got[:], want[:], "synth5000 kept steady")
		mem.tracking_allocator_clear(&heap_track)
		mem.tracking_allocator_clear(&temp_track)
		heap_track.total_allocation_count, heap_track.total_memory_allocated = 0, 0
		temp_track.total_allocation_count, temp_track.total_memory_allocated = 0, 0
		{
			free_all(context.temp_allocator)
			clear(&got)
			old_a, old_ta := context.allocator, context.temp_allocator
			context.allocator = mem.tracking_allocator(&heap_track)
			context.temp_allocator = mem.tracking_allocator(&temp_track)
			procs_read(&pr, &got)
			context.allocator, context.temp_allocator = old_a, old_ta
		}
		fmt.printfln("procs_read kept (5000, steady): wall=%.3f ms  cpu=%.3f ms  syscalls=%d (+%d tmpfs fstats; open=%d read=%d pread=%d close=%d)  heap=%d (%d B)  temp=%d (%d B)",
			median_f64(wall[:]), median_f64(cpu[:]), proc_stats_total(pr.stats, include_fstats = false), pr.stats.fstats,
			pr.stats.opens, pr.stats.reads, pr.stats.preads, pr.stats.closes,
			heap_track.total_allocation_count, heap_track.total_memory_allocated,
			temp_track.total_allocation_count, temp_track.total_memory_allocated)
	}

	// 3. Optimized Proc_Reader with fd_budget=0 (single-read fallback without kept fds)
	{
		pr0: Proc_Reader
		testing.expect(t, proc_reader_init_root(&pr0, root, fd_budget = 0))
		defer proc_reader_destroy(&pr0)

		clear(&got)
		procs_read(&pr0, &got) // warmup io_denied
		expect_counters_equal(t, got[:], want[:], "synth5000 budget=0")
		for r in 0 ..< RUNS {
			free_all(context.temp_allocator)
			clear(&got)
			t0 := time.tick_now()
			c0 := thread_cpu_ns()
			procs_read(&pr0, &got)
			c1 := thread_cpu_ns()
			t1 := time.tick_now()
			wall[r] = time.duration_milliseconds(time.tick_diff(t0, t1))
			cpu[r] = f64(c1 - c0) / 1e6
		}
		mem.tracking_allocator_clear(&heap_track)
		mem.tracking_allocator_clear(&temp_track)
		heap_track.total_allocation_count, heap_track.total_memory_allocated = 0, 0
		temp_track.total_allocation_count, temp_track.total_memory_allocated = 0, 0
		{
			free_all(context.temp_allocator)
			clear(&got)
			old_a, old_ta := context.allocator, context.temp_allocator
			context.allocator = mem.tracking_allocator(&heap_track)
			context.temp_allocator = mem.tracking_allocator(&temp_track)
			procs_read(&pr0, &got)
			context.allocator, context.temp_allocator = old_a, old_ta
		}
		fmt.printfln("procs_read budget=0 (5000):     wall=%.3f ms  cpu=%.3f ms  syscalls=%d (open=%d read=%d close=%d)  heap=%d (%d B)  temp=%d (%d B)",
			median_f64(wall[:]), median_f64(cpu[:]), proc_stats_total(pr0.stats),
			pr0.stats.opens, pr0.stats.reads, pr0.stats.closes,
			heap_track.total_allocation_count, heap_track.total_memory_allocated,
			temp_track.total_allocation_count, temp_track.total_memory_allocated)
	}

	// 4. Churn 500 processes on the 5,000-process tree (remove + spawn + PID reuse) and verify exactness + fd/map cleanup.
	{
		pr: Proc_Reader
		testing.expect(t, proc_reader_init_root(&pr, root, fd_budget = SYNTH_FDS))
		defer proc_reader_destroy(&pr)
		clear(&got)
		procs_read(&pr, &got)
		fds_before := pr.kept_fds

		for i in 0 ..< 250 {
			pid := i32(2000 + i)
			if i % 10 == 0 { _ = os.chmod(fmt.tprintf("%s/%d/io", root, pid), {.Read_User, .Write_User}) }
			_ = os.remove_all(fmt.tprintf("%s/%d", root, pid))
		}
		for i in 0 ..< 250 {
			// Reuse first 100 PIDs with new start times, and spawn 150 fresh PIDs
			pid := i < 100 ? i32(2000 + i) : i32(7000 + i)
			synth_write_proc(root, pid, 2000, fmt.tprintf("churn-%d", i), 'R', 0, u64(i), 1, 0, 1, u64(90000 + i), 80, 10, 512, 256)
		}
		free_all(context.temp_allocator)
		clear(&got)
		procs_read(&pr, &got)
		want_churn := make([dynamic]Proc_Counters, 0, USER_N, context.temp_allocator)
		_ = plain_procs_read(root, PAGE_BYTES_USUAL, &want_churn)
		expect_counters_equal(t, got[:], want_churn[:], "synth5000 after churn")
		testing.expect_value(t, len(pr.kept), USER_N)
		testing.expectf(t, pr.kept_fds <= SYNTH_FDS && pr.kept_fds <= fds_before + 100,
			"kept_fds unbounded after churn: before=%d after=%d", fds_before, pr.kept_fds)
		// Clean up spawned 7000+ dirs before defer
		for i in 100 ..< 250 { _ = os.remove_all(fmt.tprintf("%s/%d", root, 7000 + i)) }
	}
}
