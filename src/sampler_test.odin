package inspecteur

import "core:testing"
import "gt:ui"

@(test)
rates_are_differences_over_the_time :: proc(t: ^testing.T) {
	testing.expect_value(t, rate_of(1000, 3000, 2), 1000.0)
	testing.expect_value(t, rate_of(3000, 1000, 2), 0.0)   // (a counter that went back was reset)
	testing.expect_value(t, rate_of(1000, 3000, 0), 0.0)
	testing.expect_value(t, busy_percent(1000, 500, 2000, 750), 75)   // 1000 more, 250 of them idle
	testing.expect_value(t, busy_percent(1000, 500, 1000, 500), 0)
	testing.expect_value(t, busy_percent(1000, 500, 2000, 2000), 0)   // (more idle than time: none busy)
}

// A process is the pair (pid, start): the same pid with another start is a new process, which has no rates yet.
@(test)
a_pid_used_again_is_a_new_process :: proc(t: ^testing.T) {
	d: Demo
	s := Sampler{demo = &d}   // (the demo's facts: a pid it does not know is named by its comm)
	defer sampler_destroy(&s)
	SECOND :: 1_000_000_000
	procs_merge(&s, {{pid = 90001, start = 100, comm = "a", cpu_ns = 0, io_known = true}}, 0, 0, nil)
	testing.expect_value(t, len(s.procs), 1)
	procs_merge(&s, {{pid = 90001, start = 100, comm = "a", cpu_ns = SECOND / 2, io_read = 4096, io_known = true}}, 1, 4 * SECOND, nil)
	testing.expect_value(t, s.procs[0].cpu, 12.5)   // half a second of four
	testing.expect_value(t, s.procs[0].read_rate, 4096.0)
	procs_merge(&s, {{pid = 90001, start = 200, comm = "b", cpu_ns = 3 * SECOND, io_read = 99999, io_known = true}}, 1, 4 * SECOND, nil)
	testing.expect_value(t, s.procs[0].name, "b")
	testing.expect_value(t, s.procs[0].cpu, 0)
	testing.expect_value(t, s.procs[0].read_rate, 0.0)
	// a process that went is gone; one whose io is not known has no rate
	procs_merge(&s, {{pid = 90002, start = 5, comm = "c", io_known = false}}, 1, 4 * SECOND, nil)
	testing.expect_value(t, len(s.procs), 1)
	testing.expect_value(t, s.procs[0].pid, i32(90002))
	testing.expect(t, !s.procs[0].io_known)
}

// The disks and the interfaces listed again: one plugged in comes, one taken away goes, one that stays keeps its history.
@(test)
devices_come_and_go :: proc(t: ^testing.T) {
	m: Machine
	defer machine_destroy(&m)
	counters :: proc(read, busy, rx: u64) -> (c: Machine_Counters) {
		c.disks = make([dynamic]Disk_Counters, context.temp_allocator)
		c.nets = make([dynamic]Net_Counters, context.temp_allocator)
		append(&c.disks, Disk_Counters{"sda", read, 0, busy})
		append(&c.nets, Net_Counters{"eth0", rx, 0})
		return
	}
	devices_merge(&m, {{name = "sda", kind = "HDD", capacity = 100}}, {{name = "eth0", kind = "Ethernet"}})
	machine_take(&m, counters(0, 0, 0), 0, true)
	machine_take(&m, counters(2048, 500, 1000), 1, true)
	testing.expect_value(t, m.disks[0].read_rate, 2048.0)
	testing.expect_value(t, m.disks[0].active, 50)
	testing.expect_value(t, m.nets[0].rx_rate, 1000.0)
	testing.expect_value(t, len(ui.value_history_values(&m.disks[0].read_hist)), 1)
	devices_merge(&m, {{name = "sdb", kind = "SSD"}, {name = "sda", kind = "HDD"}}, {})
	testing.expect_value(t, len(m.disks), 2)
	testing.expect_value(t, m.disks[0].name, "sda")
	testing.expect_value(t, len(ui.value_history_values(&m.disks[0].read_hist)), 1)
	testing.expect_value(t, len(m.nets), 0)
	devices_merge(&m, {{name = "sdb", kind = "SSD"}}, {})
	testing.expect_value(t, len(m.disks), 1)
	testing.expect_value(t, m.disks[0].name, "sdb")
	testing.expect(t, !m.disks[0].seen, "a disk new to the list has no rate until its second reading")
}
