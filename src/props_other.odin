#+build !linux
#+build !windows
package inspecteur

// A process's details on a system not supported yet: the process is told gone, as no reader can name it.

proc_cwd :: proc(pid: i32, start: u64, allocator := context.allocator) -> (cwd: string, state: Read_State) { return "", .Gone }

proc_threads :: proc(pid: i32, start: u64, out: ^[dynamic]Thread_Row, allocator := context.allocator) -> Read_State { return .Gone }

proc_files :: proc(pid: i32, start: u64, out: ^[dynamic]File_Row, allocator := context.allocator) -> Read_State { return .Gone }

proc_modules :: proc(pid: i32, start: u64, out: ^[dynamic]Module_Row, allocator := context.allocator) -> Read_State { return .Gone }

proc_environment :: proc(pid: i32, start: u64, out: ^[dynamic]string, allocator := context.allocator) -> Read_State { return .Gone }
