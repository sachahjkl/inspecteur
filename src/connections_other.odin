#+build !linux
#+build !windows
package inspecteur

// The sockets on a system not supported yet: none.

Socket_Reader :: struct {}

socket_reader_destroy :: proc(r: ^Socket_Reader) {}

sockets_read :: proc(r: ^Socket_Reader, out: ^[dynamic]Socket) {}
