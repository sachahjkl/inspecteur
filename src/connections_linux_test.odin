package inspecteur

import "core:testing"

@(test)
a_tcp_line_gives_its_socket :: proc(t: ^testing.T) {
	text := "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" +
		"   0: 0100007F:0277 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 23456 1 0000000000000000 100 0 0 10 0\n" +
		"   1: 0F02000A:D6E2 22D8B85D:01BB 01 00000000:00000000 02:000A3D70 00000000  1000        0 98765 2 0000000000000000 20 4 30 10 -1\n"
	list := make([dynamic]Socket, context.temp_allocator)
	parse_net_sockets(text, .TCP, false, &list)
	testing.expect_value(t, len(list), 2)
	if len(list) < 2 { return }
	testing.expect_value(t, endpoint_text(list[0].local, list[0].lport, false), "127.0.0.1:631")
	testing.expect_value(t, list[0].state, Socket_State.Listening)
	testing.expect_value(t, SOCKET_STATE_TEXT[list[0].state], "Listening")
	testing.expect_value(t, remote_text(list[0]), "")
	testing.expect_value(t, list[0].key, u64(23456))
	testing.expect_value(t, endpoint_text(list[1].local, list[1].lport, false), "10.0.2.15:55010")
	testing.expect_value(t, remote_text(list[1]), "93.184.216.34:443")
	testing.expect_value(t, list[1].state, Socket_State.Established)
}

@(test)
a_tcp6_line_gives_its_socket :: proc(t: ^testing.T) {
	text := "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" +
		"   0: 00000000000000000000000001000000:0277 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 3456 1 0000000000000000 100 0 0 10 0\n" +
		"   1: 00000000000000000000000000000000:0016 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 3457 1 0000000000000000 100 0 0 10 0\n"
	list := make([dynamic]Socket, context.temp_allocator)
	parse_net_sockets(text, .TCP, true, &list)
	testing.expect_value(t, len(list), 2)
	if len(list) < 2 { return }
	testing.expect_value(t, endpoint_text(list[0].local, list[0].lport, true), "[::1]:631")
	testing.expect_value(t, endpoint_text(list[1].local, list[1].lport, true), "*:22")
}

@(test)
a_udp_socket_is_open_or_connected :: proc(t: ^testing.T) {
	text := "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops\n" +
		"  1: 00000000:0044 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 4321 2 0000000000000000 0\n" +
		"  2: 0100007F:A000 0100007F:0035 01 00000000:00000000 00:00000000 00000000  1000        0 4322 2 0000000000000000 0\n"
	list := make([dynamic]Socket, context.temp_allocator)
	parse_net_sockets(text, .UDP, false, &list)
	testing.expect_value(t, len(list), 2)
	if len(list) < 2 { return }
	testing.expect_value(t, list[0].state, Socket_State.Open)
	testing.expect_value(t, endpoint_text(list[0].local, list[0].lport, false), "*:68")
	testing.expect_value(t, list[1].state, Socket_State.Connected)
	testing.expect_value(t, remote_text(list[1]), "127.0.0.1:53")
}

@(test)
a_socket_keeps_its_identity :: proc(t: ^testing.T) {
	a := Socket{key = 42}
	b := Socket{lport = 80, rport = 5000}
	c := Socket{lport = 80, rport = 5001}
	testing.expect(t, socket_id(a) != socket_id(b))
	testing.expect(t, socket_id(b) != socket_id(c))
	testing.expect_value(t, socket_id(b), socket_id(Socket{lport = 80, rport = 5000}))
}
