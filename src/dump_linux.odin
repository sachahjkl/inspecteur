package inspecteur

// A dump file on Linux: gdb's gcore writes a core file of the process (it attaches to it with ptrace for the time it
// reads its memory, then lets it go on), into $XDG_CACHE_HOME/inspecteur/dumps. The kernel lets a user attach to a
// process of their own only when kernel.yama.ptrace_scope allows it (0; 1 allows only a process's parents), else root.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "gt:platform"
import process "gt:process"
import i18n "gt:i18n"

// What the confirmation says of how the dump is written.
DUMP_HOW := i18n.later("gdb's gcore writes it into ~/.cache/inspecteur/dumps.")

// Writes a core file of the process (pid, start) named for `name`. Returns its path, or why there is none (temporary).
process_dump :: proc(pid: i32, start: u64, name: string) -> (path: string, why: string) {
	gcore := program_in_path("gcore")
	if gcore == "" { return "", i18n.tr("gcore is not installed: it comes with gdb") }
	if s, ok := process.process_start_time(pid); !ok || s != start { return "", i18n.tr("the process has ended") }
	dir := fmt.tprintf("%s/dumps", platform.user_dir(.Cache, APP_NAME, context.temp_allocator))
	_ = os.make_directory_all(dir)
	y, mo, d := time.date(time.now())
	h, mi, sec := time.clock_from_time(time.now())
	safe, _ := strings.replace_all(name, "/", "_", context.temp_allocator)
	base := fmt.tprintf("%s/%s-%04d%02d%02d-%02d%02d%02d", dir, safe, y, int(mo), d, h, mi, sec)
	state, _, stderr, err := os.process_exec({command = {gcore, "-o", base, fmt.tprintf("%d", pid)}}, context.temp_allocator)
	// (gcore names the file <base>.<pid>)
	path = fmt.tprintf("%s.%d", base, pid)
	if err == nil && state.exited && state.exit_code == 0 && os.exists(path) {
		// (a pid given to another process while gcore read it: the file is not this process's)
		if s, ok := process.process_start_time(pid); !ok || s != start {
			_ = os.remove(path)
			return "", i18n.tr("the process ended while it was read")
		}
		return path, ""
	}
	_ = os.remove(path)
	scope := strings.trim_space(read_text("/proc/sys/kernel/yama/ptrace_scope"))
	if scope != "" && scope != "0" {
		return "", fmt.tprintf(i18n.tr("the kernel lets only a process's parents or root read its memory (kernel.yama.ptrace_scope = %s)"), scope)
	}
	text := strings.trim_space(string(stderr))
	if i := strings.last_index_byte(text, '\n'); i >= 0 { text = text[i + 1:] }
	return "", text != "" ? strings.clone(text, context.temp_allocator) : i18n.tr("gcore could not read it")
}

// The path of `name` in $PATH ("" when it is in none of its folders).
@(private = "file")
program_in_path :: proc(name: string) -> string {
	for dir in strings.split(os.get_env("PATH", context.temp_allocator), ":", context.temp_allocator) {
		if dir == "" { continue }
		p := fmt.tprintf("%s/%s", dir, name)
		if os.exists(p) { return p }
	}
	return ""
}
