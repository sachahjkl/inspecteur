package inspecteur

// Numbers as the window shows them: sizes, rates, durations, frequencies (pure: format_test.odin reads them).

import "core:fmt"
import "core:strconv"
import "core:strings"
import ascii "gt:ascii"

// "1.5 GB", "320 MB", "12 KB", "0 B": a size in powers of 1024, as most system monitors show it.
size_text :: proc(n: u64, allocator := context.temp_allocator) -> string {
	UNITS :: [?]string{"B", "KB", "MB", "GB", "TB"}
	v := f64(n)
	u := 0
	for v >= 1024 && u < len(UNITS) - 1 { v /= 1024; u += 1 }
	units := UNITS
	if u == 0 { return strings.concatenate({uint_text(n), " B"}, allocator) }
	buf: [32]u8
	digits := v < 10 ? 1 : 0
	s := strconv.write_float(buf[:], v, 'f', digits, 64)
	if len(s) > 0 && s[0] == '+' { s = s[1:] }
	return strings.concatenate({s, " ", units[u]}, allocator)
}

// A rate in bytes per second: "" when nothing moves (an empty cell reads faster than a column of zeros).
rate_text :: proc(bytes_per_s: f64, allocator := context.temp_allocator) -> string {
	if bytes_per_s < 1 { return "" }
	return strings.concatenate({size_text(u64(bytes_per_s), context.temp_allocator), "/s"}, allocator)
}

uint_text :: proc(n: u64, allocator := context.temp_allocator) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_uint(buf[:], n, 10), allocator)
}

// A name in lower case for the catalog's keys (ASCII: names and ids, not prose).
key_of :: proc(name: string, allocator := context.temp_allocator) -> string { return ascii.lower(name, allocator) }

// "1 app", "3 apps".
count_text :: proc(n: int, one, many: string) -> string { return fmt.tprintf("%d %s", n, n == 1 ? one : many) }

// CPU time: "12.34 s", "3:05.20" (minutes), "2:03:05" (hours).
cpu_time_text :: proc(ns: u64) -> string {
	s := f64(ns) / 1e9
	switch {
	case s < 60:   return fmt.tprintf("%.2f s", s)
	case s < 3600: return fmt.tprintf("%d:%05.2f", int(s) / 60, s - f64(int(s) / 60 * 60))
	}
	return fmt.tprintf("%d:%02d:%02d", int(s) / 3600, (int(s) / 60) % 60, int(s) % 60)
}

mhz_text :: proc(mhz: f32) -> string {
	if mhz <= 0 { return "–" }
	if mhz >= 1000 { return fmt.tprintf("%.2f GHz", mhz / 1000) }
	return fmt.tprintf("%.0f MHz", mhz)
}

// A network rate in bits per second, as links are told ("12.4 Mbit/s").
bits_text :: proc(bytes_per_s: f64) -> string {
	b := bytes_per_s * 8
	switch {
	case b >= 1e9: return fmt.tprintf("%.1f Gbit/s", b / 1e9)
	case b >= 1e6: return fmt.tprintf("%.1f Mbit/s", b / 1e6)
	case b >= 1e3: return fmt.tprintf("%.0f kbit/s", b / 1e3)
	}
	return fmt.tprintf("%.0f bit/s", b)
}

// "3:04:12:09" (days:hours:minutes:seconds), as Task Manager.
uptime_text :: proc(seconds: f64) -> string {
	s := i64(seconds)
	return fmt.tprintf("%d:%02d:%02d:%02d", s / 86400, (s / 3600) % 24, (s / 60) % 60, s % 60)
}

// A duration in words: "3 days, 4 h 12 min", "10 h 47 min", "5 min", "40 s".
duration_words :: proc(seconds: f64) -> string {
	s := i64(seconds)
	days, hours, minutes := s / 86400, (s / 3600) % 24, (s / 60) % 60
	switch {
	case days > 0:    return fmt.tprintf("%s, %d h %d min", count_text(int(days), "day", "days"), hours, minutes)
	case hours > 0:   return fmt.tprintf("%d h %d min", hours, minutes)
	case minutes > 0: return fmt.tprintf("%d min", minutes)
	}
	return fmt.tprintf("%d s", s)
}

// A graph's span in words, its points times the period: "60 seconds", "2 minutes", "2 min 30 s".
span_text :: proc(points, period_ms: int) -> string {
	s := points * period_ms / 1000
	switch {
	case s < 120:    return fmt.tprintf("%d seconds", s)
	case s % 60 == 0: return fmt.tprintf("%d minutes", s / 60)
	}
	return fmt.tprintf("%d min %d s", s / 60, s % 60)
}
