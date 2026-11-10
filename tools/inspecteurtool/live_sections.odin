package inspecteurtool

// live's checks of the Services, Startup, Connections and Information sections (live.odin runs them). Each acts only on
// what the test made itself: its own listening socket, its own autostart entry in the session's configuration, its own
// transient user service, checked by name before anything is pressed.

import "core:fmt"
import "core:net"
import "core:os"
import "core:time"
import cdp "gt:cdp"

// The sidebar's rows (view.odin: ###side_<tab>), in the order of the Tab enum.
SIDE_PROCESSES   :: "side_0"
SIDE_SERVICES    :: "side_2"
SIDE_STARTUP     :: "side_3"
SIDE_CONNECTIONS :: "side_4"
SIDE_INFORMATION :: "side_5"

// A TCP listener of this test on 127.0.0.1: its row says this tool's name and pid.
live_connections :: proc(l: ^Live) {
	c := &l.c
	sock, err := net.listen_tcp({net.IP4_Loopback, 0})
	if !check(l, err == nil, "a TCP listener of this test on 127.0.0.1") { return }
	defer net.close(sock)
	ep, berr := net.bound_endpoint(sock)
	if !check(l, berr == nil, "its port") { return }
	address := fmt.tprintf("127.0.0.1:%d", ep.port)
	check(l, cdp.click_name(c, SIDE_CONNECTIONS), "the Connections section")
	check(l, cdp.wait_name(c, "hd_3", SESSION_WAIT), "its table has its columns")
	check(l, cdp.type_text(c, address), "filter by %s", address)
	check(l, wait_named_text(c, "c3", address), "the listener's row is there")
	row := row_with(c, "c3", address)
	check(l, row.process == "inspecteurtool" && row.pid == fmt.tprintf("%d", os.get_pid()) && row.state == "Listening",
		"its process is this test (%s, PID %s), it listens (%s)", row.process, row.pid, row.state)
	check(l, cdp.key(c, "Escape"), "Escape clears the filter")
	cdp.wait_idle(c, SESSION_WAIT)
	check(l, cdp.shot(c, fmt.tprintf("%s/connections.png", l.dir)), "a picture of the section")
}

// The cells of the row whose cell `name` says `text`: the process (c0), the PID (c1), the state (c5).
Row_Cells :: struct { process, pid, state: string }

row_with :: proc(c: ^cdp.Client, name, text: string) -> (r: Row_Cells) {
	for b in cdp.find_name(c, name) {
		if b.text != text { continue }
		mid := b.y + b.h / 2
		cell :: proc(c: ^cdp.Client, name: string, mid: f64) -> string {
			for x in cdp.find_name(c, name) { if x.y <= mid && mid <= x.y + x.h { return x.text } }
			return ""
		}
		return {cell(c, "c0", mid), cell(c, "c1", mid), cell(c, "c5", mid)}
	}
	return
}

// A box named `name` comes to say `text`.
wait_named_text :: proc(c: ^cdp.Client, name, text: string) -> bool {
	deadline := time.tick_add(time.tick_now(), SESSION_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		for b in cdp.find_name(c, name) { if b.text == text { return true } }
		time.sleep(SESSION_POLL)
	}
	return false
}
