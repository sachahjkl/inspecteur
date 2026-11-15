#+build !linux
package inspecteur

// The processes on a system not supported yet: the reader cannot open, so the window says the reading failed instead
// of showing an empty list as if it were true.

Proc_Reader :: struct {}

proc_reader_init :: proc(r: ^Proc_Reader) -> bool { return false }

proc_reader_destroy :: proc(r: ^Proc_Reader) { r^ = {} }

procs_read :: proc(r: ^Proc_Reader, out: ^[dynamic]Proc_Counters) {}

proc_facts :: proc(r: ^Proc_Reader, c: Proc_Counters) -> (f: Proc_Facts) { return }

proc_state_now :: proc(pid: i32, start: u64) -> Proc_State { return .Unknown }
