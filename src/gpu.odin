package inspecteur

// The GPUs, read on a thread of their own every GPU_PERIOD (gpu_linux.odin: gpu_read): a GPU's driver can take
// milliseconds to answer, and its library a second to start; the window's thread never waits for them. The window takes
// the last reading at each sample (gpus_sample); its graphs get a point per reading.
//
// A GPU that the system has put to sleep (a laptop's second GPU) is not woken to be read: it is listed "asleep". The
// window says whether the GPUs' numbers are wanted (`wanted`: the Performance section or the GPU memory column is
// shown); while they are not, the reader lets go of what keeps a GPU awake.

import "core:sync"
import "core:thread"
import "core:time"
import "gt:ui"

GPU_PERIOD :: 2 * time.Second
GPU_MAX :: 4
// The processes whose video memory is kept, at most.
GPU_PROCS_MAX :: 256

// One reading of a GPU. Fixed size: it is copied from the GPU thread to the window's under the lock.
Gpu_Read :: struct {
	name:        [96]u8,
	name_len:    int,
	vendor:      string,   // a literal: NVIDIA, AMD, Intel
	driver:      [32]u8,
	driver_len:  int,
	asleep:      bool,     // the system put it to sleep: it was not read (reading it would wake it)
	has_util, has_mem, has_temp, has_power, has_clock: bool,
	util:        f32,   // percent
	mem_used, mem_total: u64,
	temp_c:      f32,
	power_w:     f32,
	clock_mhz:   f32,
}

Gpu_Proc_Mem :: struct { pid: i32, bytes: u64 }

Gpu_Snapshot :: struct {
	gpus:      [GPU_MAX]Gpu_Read,
	count:     int,
	procs:     [GPU_PROCS_MAX]Gpu_Proc_Mem,
	proc_count: int,
	readings:  int,   // how many readings have been made (0: none yet)
}

Gpu_Watch :: struct {
	thread: ^thread.Thread,
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	stop:   bool,
	wanted: bool,           // under the mutex: the window shows the GPUs' numbers
	demo:   ^Demo,          // not nil: the GPUs are the demo's
	snap:   Gpu_Snapshot,   // the last reading, under the mutex
}

// A GPU as the window has it: its last reading and its graphs.
Gpu :: struct {
	read:      Gpu_Read,
	util_hist: History,
	mem_hist:  History,   // percent of its memory in use
	temp_hist: History,   // degrees Celsius (when it tells them)
}

gpu_name :: proc(g: ^Gpu_Read) -> string { return string(g.name[:g.name_len]) }
gpu_driver :: proc(g: ^Gpu_Read) -> string { return string(g.driver[:g.driver_len]) }

gpu_start :: proc(w: ^Gpu_Watch, demo: ^Demo) {
	w.demo = demo
	w.thread = thread.create_and_start_with_data(w, gpu_run, context)
}

gpu_stop :: proc(w: ^Gpu_Watch) {
	if w.thread == nil { return }
	sync.mutex_lock(&w.mutex)
	w.stop = true
	sync.cond_signal(&w.cond)
	sync.mutex_unlock(&w.mutex)
	thread.join(w.thread)
	thread.destroy(w.thread)
	w.thread = nil
}

// Says whether the GPUs' numbers are wanted; a change wakes the thread at once (a page opened reads now).
gpu_want :: proc(w: ^Gpu_Watch, wanted: bool) {
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if w.wanted == wanted { return }
	w.wanted = wanted
	sync.cond_signal(&w.cond)
}

// The GPUs' last reading into the machine; a point of each graph when it is a new reading. The processes' video
// memory: gpu_proc_mem.
gpus_sample :: proc(m: ^Machine, history: bool) {
	w := &m.gpu
	sync.mutex_lock(&w.mutex)
	snap := w.snap
	sync.mutex_unlock(&w.mutex)
	if snap.readings == 0 { return }
	if len(m.gpus) != snap.count { resize(&m.gpus, snap.count) }
	fresh := snap.readings != m.gpu_readings
	m.gpu_readings = snap.readings
	for &g, i in m.gpus {
		g.read = snap.gpus[i]
		if fresh && history {
			ui.value_history_push(&g.util_hist, g.read.util)
			ui.value_history_push(&g.mem_hist, g.read.mem_total > 0 ? 100 * f32(f64(g.read.mem_used) / f64(g.read.mem_total)) : 0)
			if g.read.has_temp { ui.value_history_push(&g.temp_hist, g.read.temp_c) }
		}
	}
}

// The video memory each process holds, by pid, over every GPU (temporary allocator; empty when no GPU tells it).
gpu_proc_mem :: proc(m: ^Machine) -> map[i32]u64 {
	out := make(map[i32]u64, 16, context.temp_allocator)
	w := &m.gpu
	sync.mutex_lock(&w.mutex)
	for p in w.snap.procs[:w.snap.proc_count] { out[p.pid] += p.bytes }
	sync.mutex_unlock(&w.mutex)
	return out
}

@(private = "file")
gpu_run :: proc(data: rawptr) {
	w := (^Gpu_Watch)(data)
	r: Gpu_Reader
	defer if w.demo == nil { gpu_reader_close(&r) }
	sync.mutex_lock(&w.mutex)
	wanted := w.wanted
	sync.mutex_unlock(&w.mutex)
	for {
		snap: Gpu_Snapshot
		if w.demo != nil { demo_gpus_read(w.demo, &snap) } else { gpu_read(&r, &snap, wanted) }
		sync.mutex_lock(&w.mutex)
		snap.readings = w.snap.readings + 1
		w.snap = snap
		if !w.stop && w.wanted == wanted { _ = sync.cond_wait_with_timeout(&w.cond, &w.mutex, GPU_PERIOD) }
		stop := w.stop
		wanted = w.wanted
		sync.mutex_unlock(&w.mutex)
		free_all(context.temp_allocator)
		if stop { return }
	}
}

// Adds the video memory of process `pid` on one GPU to the snapshot: a process that both draws and computes on it is
// counted once (`first`: where that GPU's processes start); on two GPUs it is counted on each.
gpu_proc_add :: proc(snap: ^Gpu_Snapshot, first: int, pid: i32, bytes: u64) {
	for q in snap.procs[first:snap.proc_count] { if q.pid == pid { return } }
	if snap.proc_count < GPU_PROCS_MAX {
		snap.procs[snap.proc_count] = {pid, bytes}
		snap.proc_count += 1
	}
}
