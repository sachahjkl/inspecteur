#+build !windows
package inspecteur

// The Processes table's columns on Linux and macOS.

import "core:fmt"
import i18n "gt:i18n"

// Memory is a process's private memory: the pages that are its own. The resident memory counts the pages it shares with
// others too (its libraries, shared memory): summed over a group, it would count them once per process.
Column :: enum u8 { Name, PID, PPID, User, State, Nice, CPU, CPU_Graph, Memory, Resident, GPU, GPU_Memory, Read, Write, Threads, Started, Command, Executable }

COLUMN_NAMES := [Column]string{
	.Name = i18n.later("Name"), .PID = i18n.later("PID"), .PPID = i18n.later("Parent PID"), .User = i18n.later("User"), .State = i18n.later("State"), .Nice = PRIORITY_COLUMN, .CPU = i18n.later("CPU"), .CPU_Graph = i18n.later("CPU, 30 s"),
	.Memory = i18n.later("Private memory"), .Resident = i18n.later("Resident"), .GPU = i18n.later("GPU"), .GPU_Memory = i18n.later("GPU memory"), .Read = i18n.later("Disk read"), .Write = i18n.later("Disk write"),
	.Threads = i18n.later("Threads"), .Started = i18n.later("Started"), .Command = i18n.later("Command line"), .Executable = i18n.later("Executable"),
}

// The names in the preferences (processes.columns, processes.widths, processes.sort).
COLUMN_KEYS := [Column]string{
	.Name = "name", .PID = "pid", .PPID = "ppid", .User = "user", .State = "state", .Nice = "nice", .CPU = "cpu", .CPU_Graph = "cpu_graph",
	.Memory = "memory", .Resident = "resident", .GPU = "gpu", .GPU_Memory = "gpu_memory", .Read = "read", .Write = "write",
	.Threads = "threads", .Started = "started", .Command = "command", .Executable = "executable",
}

// The columns of text, on the left of their cells; numbers are on the right.
COLUMN_TEXT :: bit_set[Column]{.Name, .User, .State, .Started, .Command, .Executable}

// Each column's width when none was chosen, in ems (Name takes the room the others leave).
COLUMN_DEFAULT_EM := [Column]f32{
	.Name = 0, .PID = 5.5, .PPID = 6.5, .User = 6.5, .State = 7, .Nice = 4.5, .CPU = 5.5, .CPU_Graph = 6.5, .Memory = 8.5, .Resident = 7,
	.GPU = 5.5, .GPU_Memory = 7, .Read = 7, .Write = 7, .Threads = 5.5, .Started = 9.5, .Command = 22, .Executable = 18,
}

Group_Extra :: struct {}

column_low_first :: proc(c: Column) -> bool {
	return c == .PID || c == .PPID || c == .Nice
}

group_extra_sum :: proc(g: ^Group_Extra, p: Proc) {}

sort_group_extra :: proc(it: ^Sort_Item, sort: Column, g: Group, root: ^Proc) -> bool {
	return false
}

sort_value_extra :: proc(it: ^Sort_Item, c: Column, p: ^Proc) {}

nice_cell_text :: proc(nice: i8) -> string {
	return fmt.tprintf("%d", nice)
}

build_cell_extra :: proc(app: ^App, t: ^Table, c: Column, r: Row, p: Proc, g: ^Group, weak: bool, tip: ^string) {}
