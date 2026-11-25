package inspecteur

// Windows process memory dump via MiniDumpWriteDump (dbghelp.dll, loaded dynamically).
// Runs on a worker thread (called from menu.odin's dump task), verifies (pid, creation_time)
// on the open process handle, refuses critical and protected (PPL) processes cleanly, and writes
// into %LOCALAPPDATA%\FromentSoftware\Inspecteur\dumps.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"
import i18n "gt:i18n"
import "gt:platform"

DUMP_HOW := i18n.later("Windows writes a minidump (.dmp) into %LOCALAPPDATA%\\FromentSoftware\\Inspecteur\\dumps.")

@(private = "file") dump_lock: sync.Mutex

@(private = "file")
MiniDumpWriteDump_Proc :: #type proc "system" (
	hProcess:        win.HANDLE,
	ProcessId:       win.DWORD,
	hFile:           win.HANDLE,
	DumpType:        u32,
	ExceptionParam:  rawptr,
	UserStreamParam: rawptr,
	CallbackParam:   rawptr,
) -> win.BOOL

@(private = "file") MINIDUMP_NORMAL              :: u32(0x00000000)
@(private = "file") MINIDUMP_WITH_FULL_MEMORY    :: u32(0x00000002)
@(private = "file") MINIDUMP_WITH_HANDLE_DATA    :: u32(0x00000004)
@(private = "file") MINIDUMP_WITH_UNLOADED_MODS  :: u32(0x00000020)
@(private = "file") MINIDUMP_WITH_THREAD_INFO    :: u32(0x00001000)
@(private = "file") MINIDUMP_IGNORE_INACCESSIBLE :: u32(0x00020000)

// A process that changes while it is read gives ERROR_PARTIAL_COPY: tried again, so many times.
@(private = "file") DUMP_TRIES   :: 4
@(private = "file") DUMP_WAIT    :: 100 * time.Millisecond
@(private = "file") DUMP_PARTIAL :: win.DWORD(299)

// Writes a minidump of process (pid, start) named for `name`. Returns path or error reason (temporary).
process_dump :: proc(pid: i32, start: u64, name: string) -> (path: string, why: string) {
	// (DbgHelp is not made for two threads at once)
	sync.lock(&dump_lock)
	defer sync.unlock(&dump_lock)
	lib := win_system_library("dbghelp.dll")
	if lib == nil { return "", i18n.tr("dbghelp.dll is not available on this system") }
	defer win.FreeLibrary(lib)

	fn := (MiniDumpWriteDump_Proc)(win.GetProcAddress(lib, "MiniDumpWriteDump"))
	if fn == nil { return "", i18n.tr("MiniDumpWriteDump is not available in dbghelp.dll") }

	h, res, _, refusal, label := win_open_for_act(pid, start, WIN_PROCESS_QUERY_INFORMATION | WIN_PROCESS_VM_READ | WIN_PROCESS_DUP_HANDLE)
	switch {
	case refusal == .Critical:  return "", i18n.tr("refused: critical Windows processes are not dumped")
	case refusal == .Protected: return "", fmt.tprintf(i18n.tr("refused: protected process (%s) cannot be read"), label)
	case res == .Gone:          return "", i18n.tr("the process has ended")
	case res == .Denied:        return "", i18n.tr("access denied: run Inspecteur as an administrator to dump this process")
	case res != .Done:          return "", i18n.tr("the process memory cannot be opened")
	}
	defer win.CloseHandle(h)

	base_dir := platform.user_dir(.Cache, APP_FOLDER, context.temp_allocator)
	if base_dir == "" { base_dir = os.get_env("TEMP", context.temp_allocator) }
	if base_dir == "" { base_dir = "." }
	dir := fmt.tprintf("%s\\dumps", strings.trim_right(base_dir, "\\/"))
	_ = os.make_directory_all(dir)

	y, mo, d := time.date(time.now())
	hr, mi, sec := time.clock_from_time(time.now())
	safe := strings.clone(name, context.temp_allocator)
	for bad in ([]string{"\\", "/", ":", "*", "?", "\"", "<", ">", "|"}) {
		safe, _ = strings.replace_all(safe, bad, "_", context.temp_allocator)
	}
	if safe == "" { safe = "process" }
	path = fmt.tprintf("%s\\%s-%d-%04d%02d%02d-%02d%02d%02d.dmp", dir, safe, pid, y, int(mo), d, hr, mi, sec)

	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	fh := win.CreateFileW(wpath, win.GENERIC_READ | win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if fh == win.INVALID_HANDLE_VALUE {
		return "", fmt.tprintf(i18n.tr("cannot create dump file (error %d)"), int(win.GetLastError()))
	}

	full_flags := MINIDUMP_WITH_FULL_MEMORY | MINIDUMP_WITH_HANDLE_DATA | MINIDUMP_WITH_UNLOADED_MODS | MINIDUMP_WITH_THREAD_INFO | MINIDUMP_IGNORE_INACCESSIBLE
	lite_flags := MINIDUMP_NORMAL | MINIDUMP_WITH_HANDLE_DATA | MINIDUMP_WITH_THREAD_INFO
	// (its error is an HRESULT, the Win32 error in its low half)
	write :: proc(fn: MiniDumpWriteDump_Proc, h: win.HANDLE, pid: i32, fh: win.HANDLE, flags: u32) -> (hr: win.DWORD) {
		for i in 0 ..< DUMP_TRIES {
			if i > 0 { time.sleep(DUMP_WAIT) }
			_ = win.SetFilePointerEx(fh, 0, nil, win.FILE_BEGIN)
			_ = win.SetEndOfFile(fh)
			if fn(h, win.DWORD(pid), fh, flags, nil, nil, nil) { return 0 }
			hr = win.GetLastError()
			if hr == 0 { hr = 0x80004005 }   // (E_FAIL: it failed and says nothing)
			if hr & 0xFFFF != DUMP_PARTIAL { return }
		}
		return
	}
	last_err := write(fn, h, pid, fh, full_flags)
	// Without its memory when all of it cannot be had (a full disk).
	if last_err != 0 && last_err & 0xFFFF != DUMP_PARTIAL { last_err = write(fn, h, pid, fh, lite_flags) }
	win.CloseHandle(fh)

	if last_err != 0 {
		_ = os.remove(path)
		if last_err & 0xFFFF == win.ERROR_ACCESS_DENIED {
			return "", i18n.tr("access denied: run Inspecteur as an administrator to dump this process")
		}
		if last_err & 0xFFFF == DUMP_PARTIAL {
			return "", i18n.tr("its memory cannot be read whole (error 299): it is still starting, it ends, or it changes too fast")
		}
		return "", fmt.tprintf(i18n.tr("MiniDumpWriteDump failed (error %s)"), fmt.tprintf("0x%08X", u32(last_err)))
	}
	return path, ""
}
