package inspecteur

// Windows-native columns for the Processes table.
// Keeps common column enum names (Name, PID, Memory, Resident, etc.) while exposing Windows concepts:
// Working set, Commit charge, Handles, Session ID, Integrity level, Efficiency mode (EcoQoS), and UWP Package.

import "core:fmt"
import i18n "gt:i18n"
import timefmt "gt:timefmt"
import "gt:ui"

Column :: enum u8 {
	Name, PID, PPID, User, State, Nice, CPU, CPU_Graph, Memory, Resident, Commit,
	GPU, GPU_Memory, Read, Write, Threads, Handles, Session, Integrity, Efficiency, Package,
	Started, Command, Executable,
}

COLUMN_NAMES := [Column]string{
	.Name       = i18n.later("Name"),
	.PID        = i18n.later("PID"),
	.PPID       = i18n.later("Parent PID"),
	.User       = i18n.later("User"),
	.State      = i18n.later("State"),
	.Nice       = PRIORITY_COLUMN,
	.CPU        = i18n.later("CPU"),
	.CPU_Graph  = i18n.later("CPU, 30 s"),
	.Memory     = i18n.later("Private memory"),
	.Resident   = i18n.later("Working set"),
	.Commit     = i18n.later("Commit"),
	.GPU        = i18n.later("GPU"),
	.GPU_Memory = i18n.later("GPU memory"),
	.Read       = i18n.later("Disk read"),
	.Write      = i18n.later("Disk write"),
	.Threads    = i18n.later("Threads"),
	.Handles    = i18n.later("Handles"),
	.Session    = i18n.later("Session"),
	.Integrity  = i18n.later("Integrity"),
	.Efficiency = i18n.later("Efficiency"),
	.Package    = i18n.later("Package"),
	.Started    = i18n.later("Started"),
	.Command    = i18n.later("Command line"),
	.Executable = i18n.later("Executable"),
}

COLUMN_KEYS := [Column]string{
	.Name = "name", .PID = "pid", .PPID = "ppid", .User = "user", .State = "state", .Nice = "nice",
	.CPU = "cpu", .CPU_Graph = "cpu_graph", .Memory = "memory", .Resident = "resident", .Commit = "commit",
	.GPU = "gpu", .GPU_Memory = "gpu_memory", .Read = "read", .Write = "write", .Threads = "threads",
	.Handles = "handles", .Session = "session", .Integrity = "integrity", .Efficiency = "efficiency",
	.Package = "package", .Started = "started", .Command = "command", .Executable = "executable",
}

COLUMN_TEXT :: bit_set[Column]{.Name, .User, .State, .Nice, .Integrity, .Efficiency, .Package, .Started, .Command, .Executable}

COLUMN_DEFAULT_EM := [Column]f32{
	.Name = 0, .PID = 5.5, .PPID = 6.5, .User = 10, .State = 7, .Nice = 8.5, .CPU = 5.5, .CPU_Graph = 6.5,
	.Memory = 8.5, .Resident = 7.5, .Commit = 7.5, .GPU = 5.5, .GPU_Memory = 7, .Read = 7, .Write = 7,
	.Threads = 5.5, .Handles = 6, .Session = 5.5, .Integrity = 8, .Efficiency = 7, .Package = 16,
	.Started = 9.5, .Command = 22, .Executable = 18,
}

Group_Extra :: struct {
	commit:  u64,
	handles: u32,
}

column_low_first :: proc(c: Column) -> bool {
	return c == .PID || c == .PPID || c == .Nice || c == .Session
}

group_extra_sum :: proc(g: ^Group_Extra, p: Proc) {
	g.commit += p.extra.commit
	g.handles += p.extra.handles
}

sort_group_extra :: proc(it: ^Sort_Item, sort: Column, g: Group, root: ^Proc) -> bool {
	#partial switch sort {
	case .Commit:  it.num = f64(g.extra.commit); return true
	case .Handles: it.num = f64(g.extra.handles); return true
	}
	return false
}

sort_value_extra :: proc(it: ^Sort_Item, c: Column, p: ^Proc) {
	#partial switch c {
	case .Commit:     it.num = f64(p.extra.commit)
	case .Handles:    it.num = f64(p.extra.handles)
	case .Session:    it.num = f64(p.extra.session_id)
	case .Integrity:  it.num = f64(p.extra.integrity)
	case .Efficiency: it.num = p.extra.efficiency ? 1 : 0
	case .Package:    it.text = p.extra.uwp_package
	}
}

nice_cell_text :: proc(nice: i8) -> string {
	return priority_text(nice)
}

build_cell_extra :: proc(app: ^App, t: ^Table, c: Column, r: Row, p: Proc, g: ^Group, weak: bool, tip: ^string) {
	text := ""
	dim := weak
	#partial switch c {
	case .Commit:
		v := g != nil ? g.extra.commit : p.extra.commit
		text = timefmt.size(i64(v))
		dim = true
	case .Handles:
		v := g != nil ? g.extra.handles : p.extra.handles
		text = fmt.tprintf("%d", v)
	case .Session:
		text = fmt.tprintf("%d", p.extra.session_id)
		dim = true
	case .Integrity:
		text = integrity_label(p.extra.integrity)
		if p.extra.elevated && text != "" { text = fmt.tprintf("%s (%s)", text, i18n.tr("Admin")) }
		dim = p.extra.integrity != .System && p.extra.integrity != .Protected
	case .Efficiency:
		text = p.extra.efficiency ? i18n.tr("EcoQoS") : ""
		dim = false
	case .Package:
		text = p.extra.uwp_package
		dim = true
	}
	if dim { ui.push_tags("weak") }
	defer if dim { ui.pop_tags() }
	if ui.table_cell(&t.layout, int(c), text) { tip^ = text }
}
