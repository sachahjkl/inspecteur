package inspecteur

// What the window says of the system that is Linux's own: the priorities offered (nice values), the name of the
// administrator. A port writes its own (src/md/infrastructure/porting.md).

import "core:fmt"
import i18n "gt:i18n"
import timefmt "gt:timefmt"

// The priorities offered, as nice values: -20 is served first, 19 last. A user may only lower a process's priority
// (raise its nice) without CAP_SYS_NICE: the others are refused ("Access denied").
PRIORITIES := [?]Priority{
	{i18n.later("High (-10)"), -10}, {i18n.later("Above normal (-5)"), -5}, {i18n.later("Normal (0)"), 0}, {i18n.later("Below normal (5)"), 5}, {i18n.later("Low (10)"), 10}, {i18n.later("Idle (19)"), 19},
}

// The Processes table's title of the priority's column.
PRIORITY_COLUMN := i18n.later("Nice")

// Who may act on any process.
ADMIN :: "root"

// No system task manager to take the place of (src/md/features/install.md): the install shows no such box.
SETUP_TASK_MANAGER_WORDS :: ""

// Why a priority was refused.
PRIORITY_DENIED := i18n.later("only root may raise a priority, or change another user's process")

PROCS_READ_FAILED := i18n.later("The processes cannot be read (/proc)")
HANDLES_LABEL     := i18n.later("Open files")
GPU_NVIDIA_MISSING := i18n.later("This GPU's numbers come with NVIDIA's driver library (libnvidia-ml), not found or not answering.")

// A priority as the window says it: "nice 5".
priority_text :: proc(nice: i8) -> string { return fmt.tprintf(i18n.tr("nice %d"), nice) }

// The numbers of the Memory page: those of the composition, and what the kernel keeps besides: the files it caches, the
// buffers of the disks, what processes share, what is still to be written.
memory_page_stats :: proc(m: ^Machine, in_use: u64) -> (big, details: []Stat) {
	mem := m.mem
	swap_used := mem.swap_total - min(mem.swap_total, mem.swap_free)
	b := make([]Stat, 5, context.temp_allocator)
	b[0] = {i18n.tr("In use"), timefmt.size(i64(in_use))}
	b[1] = {i18n.tr("Available"), timefmt.size(i64(mem.available))}
	b[2] = {i18n.tr("Free"), timefmt.size(i64(mem.free))}
	b[3] = {i18n.tr("Committed"), fmt.tprintf("%s / %s", timefmt.size(i64(mem.committed)), timefmt.size(i64(mem.commit_limit)))}
	b[4] = {i18n.tr("Swap"), fmt.tprintf("%s / %s", timefmt.size(i64(swap_used)), timefmt.size(i64(mem.swap_total)))}
	d := make([]Stat, 6, context.temp_allocator)
	d[0] = {i18n.tr("Total"), timefmt.size(i64(mem.total))}
	d[1] = {i18n.tr("Files cached"), timefmt.size(i64(mem.cached))}
	d[2] = {i18n.tr("Disk buffers"), timefmt.size(i64(mem.buffers))}
	d[3] = {i18n.tr("Kernel, reclaimable"), timefmt.size(i64(mem.reclaimable))}
	d[4] = {i18n.tr("Shared memory"), timefmt.size(i64(mem.shared))}
	d[5] = {i18n.tr("To be written"), timefmt.size(i64(mem.dirty))}
	return b, d
}
