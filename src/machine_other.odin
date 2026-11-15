#+build !linux
package inspecteur

// The machine on a system not supported yet: no counters, no devices.

Machine_Reader :: struct {}

machine_reader_init :: proc(r: ^Machine_Reader) {}

machine_reader_destroy :: proc(r: ^Machine_Reader) {}

machine_read :: proc(r: ^Machine_Reader, c: ^Machine_Counters) {
	// (the same allocator as Linux's lists: the caller never frees them)
	c.core_total_ns = make([dynamic]u64, context.temp_allocator)
	c.core_idle_ns = make([dynamic]u64, context.temp_allocator)
	c.disks = make([dynamic]Disk_Counters, context.temp_allocator)
	c.nets = make([dynamic]Net_Counters, context.temp_allocator)
}

cpu_info_read :: proc() -> (info: Cpu_Info) { return }

cpu_mhz_now :: proc(cores: []f32) -> f32 { return 0 }

disks_list :: proc(out: ^[dynamic]Disk_Info) {}

nets_list :: proc(out: ^[dynamic]Net_Info) {}
