package inspecteur

import "core:fmt"
import "core:testing"

@(test)
machine_files_are_read :: proc(t: ^testing.T) {
	d := parse_diskstats(" 259       0 nvme0n1 703 0 31386 88 4 0 40 0 0 68 88 0 0 0 0 0 0\n   8       0 sda 10 0 20 1 2 0 8 3 0 7 4\n")
	testing.expect_value(t, len(d), 2)
	testing.expect_value(t, d[0].name, "nvme0n1")
	testing.expect_value(t, d[0].sectors_read, u64(31386))
	testing.expect_value(t, d[0].sectors_written, u64(40))
	testing.expect_value(t, d[0].io_ms, u64(68))
	n := parse_net_dev("Inter-|   Receive |  Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes\n  enp10s0: 1000 5 0 0 0 0 0 0 2000 7 0 0 0 0 0 0\n    lo: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n")
	testing.expect_value(t, len(n), 2)
	testing.expect_value(t, n[0].name, "enp10s0")
	testing.expect_value(t, n[0].rx, u64(1000))
	testing.expect_value(t, n[0].tx, u64(2000))
	l := parse_loadavg("0.52 1.25 2.00 2/1234 5678\n")
	testing.expect_value(t, l, [3]f32{0.52, 1.25, 2})
	testing.expect_value(t, parse_size_k("512K"), u64(512 * 1024))
	testing.expect_value(t, parse_size_k("32768K"), u64(32 * 1024 * 1024))
	m := parse_meminfo("MemTotal:       32000000 kB\nMemFree:  100 kB\nMemAvailable:   20000000 kB\nBuffers: 1 kB\nCached: 2 kB\nSReclaimable: 3 kB\nSwapTotal: 4 kB\nSwapFree: 1 kB\n")
	testing.expect_value(t, m.free, u64(100 * 1024))
	testing.expect_value(t, m.cached, u64(2 * 1024))
	testing.expect_value(t, m.swap_total - m.swap_free, u64(3 * 1024))
}

@(test)
cpu_topology_is_counted :: proc(t: ^testing.T) {
	// two sockets of two cores, each core two logical processors
	text := ""
	for i in 0 ..< 8 {
		text = fmt.tprintf("%sprocessor\t: %d\nmodel name\t: Test CPU\nphysical id\t: %d\ncore id\t\t: %d\n\n", text, i, i / 4, (i / 2) % 2)
	}
	c := parse_cpuinfo(text)
	defer delete(c.model)
	testing.expect_value(t, c.model, "Test CPU")
	testing.expect_value(t, c.logical, 8)
	testing.expect_value(t, c.sockets, 2)
	testing.expect_value(t, c.cores, 4)
}

@(test)
pressure_is_read :: proc(t: ^testing.T) {
	p := parse_pressure("some avg10=13.81 avg60=12.68 avg300=13.19 total=22814585738\nfull avg10=12.04 avg60=9.99 avg300=10.34 total=20216196013\n")
	testing.expect_value(t, p, Pressure{some10 = 13.81, some60 = 12.68, full10 = 12.04, full60 = 9.99})
	// (a kernel that tells no "full" line for the CPU)
	q := parse_pressure("some avg10=0.23 avg60=1.59 avg300=1.89 total=2463812561\n")
	testing.expect(t, q.some60 == 1.59 && q.full10 == 0, "some alone")
}

@(test)
core_labels_give_their_core :: proc(t: ^testing.T) {
	id, ok := core_label_id("Core 12")
	testing.expect(t, ok && id == 12)
	_, ok = core_label_id("Package id 0")
	testing.expect(t, !ok)
	_, ok = core_label_id("Core x")
	testing.expect(t, !ok)
}
