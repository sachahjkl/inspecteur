#+build !linux
#+build !windows
package inspecteur

// The GPUs on a system not supported yet: none.

Gpu_Reader :: struct {}

gpu_reader_close :: proc(r: ^Gpu_Reader) {}

gpu_read :: proc(r: ^Gpu_Reader, snap: ^Gpu_Snapshot, wanted: bool) {}
