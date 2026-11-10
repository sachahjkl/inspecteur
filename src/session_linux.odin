package inspecteur

// The session on Linux: which process draws the desktop. A Wayland compositor is the peer of the socket
// $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY: the kernel tells a connection's peer (SO_PEERCRED). Suspending it would freeze
// every window, this one too, with no way to resume it from here; ending it ends the session.

import "core:os"
import "core:strings"
import "core:sys/linux"

@(private = "file")
SOL_SOCKET :: 1
@(private = "file")
SO_PEERCRED :: 17

@(private = "file")
Ucred :: struct { pid: i32, uid, gid: u32 }

// The pid of the display server the window is shown by (0 when it cannot be told: X11, or no socket).
display_server_pid :: proc() -> i32 {
	display := os.get_env("WAYLAND_DISPLAY", context.temp_allocator)
	if display == "" { return 0 }
	path := display
	if !strings.has_prefix(display, "/") {
		runtime := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
		if runtime == "" { return 0 }
		path = strings.concatenate({runtime, "/", display}, context.temp_allocator)
	}
	addr: linux.Sock_Addr_Un
	if len(path) >= len(addr.sun_path) { return 0 }
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], path)
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, {})
	if err != .NONE { return 0 }
	defer linux.close(fd)
	if linux.connect(fd, &addr) != .NONE { return 0 }
	cred: Ucred
	size := u32(size_of(Ucred))
	// (the raw call: the size is a pointer to the struct's size)
	if ret := linux.syscall(linux.SYS_getsockopt, fd, SOL_SOCKET, SO_PEERCRED, &cred, &size); ret < 0 { return 0 }
	return cred.pid
}
