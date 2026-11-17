package inspecteur

// Numbers as the window shows them: durations, frequencies (pure: format_test.odin reads them). Sizes, rates and the
// uptime are the toolkit's (gt:timefmt: size, rate, stopwatch).

import "core:fmt"
import "core:strconv"
import "core:strings"
import ascii "gt:ascii"
import i18n "gt:i18n"
import timefmt "gt:timefmt"

// A rate in bytes per second in a table's cell: "" when nothing moves (an empty cell reads faster than a column of
// zeros).
rate_text :: proc(bytes_per_s: f64) -> string { return bytes_per_s < 1 ? "" : timefmt.rate(bytes_per_s) }

uint_text :: proc(n: u64, allocator := context.temp_allocator) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_uint(buf[:], n, 10), allocator)
}

// A name in lower case for the catalog's keys (ASCII: names and ids, not prose).
key_of :: proc(name: string, allocator := context.temp_allocator) -> string { return ascii.lower(name, allocator) }

// CPU time: "12.34 s", "3:05.20" (minutes), "2:03:05" (hours).
cpu_time_text :: proc(ns: u64) -> string {
	s := f64(ns) / 1e9
	// (every number a person reads with the language's decimal mark: i18n.decimal, i18n.percent)
	switch {
	case s < 60:   return fmt.tprintf("%s s", i18n.decimal(s, 2))
	case s < 3600: return i18n.decimal_marks(fmt.tprintf("%d:%05.2f", int(s) / 60, s - f64(int(s) / 60 * 60)))
	}
	return fmt.tprintf("%d:%02d:%02d", int(s) / 3600, (int(s) / 60) % 60, int(s) % 60)
}

mhz_text :: proc(mhz: f32) -> string {
	if mhz <= 0 { return "–" }
	if mhz >= 1000 { return fmt.tprintf("%s GHz", i18n.decimal(f64(mhz) / 1000, 2)) }
	return fmt.tprintf("%.0f MHz", mhz)
}

// A share of 0..100 as the language writes a percent: "34%" in English, "34 %" in French.
percent_text :: proc(v: f64, decimals := 0) -> string { return i18n.percent(v / 100, decimals) }

// A network rate in bits per second, as links are told ("12.4 Mbit/s").
bits_text :: proc(bytes_per_s: f64) -> string {
	b := bytes_per_s * 8
	switch {
	case b >= 1e9: return fmt.tprintf("%s Gbit/s", i18n.decimal(b / 1e9, 1))
	case b >= 1e6: return fmt.tprintf("%s Mbit/s", i18n.decimal(b / 1e6, 1))
	case b >= 1e3: return fmt.tprintf("%.0f kbit/s", b / 1e3)
	}
	return fmt.tprintf("%.0f bit/s", b)
}

// A duration in words: "3 days, 4 h 12 min", "10 h 47 min", "5 min", "40 s".
duration_words :: proc(seconds: f64) -> string {
	s := i64(seconds)
	days, hours, minutes := s / 86400, (s / 3600) % 24, (s / 60) % 60
	switch {
	case days > 0:    return fmt.tprintf(i18n.tr(int(days), "%d day, %d h %d min", "%d days, %d h %d min"), days, hours, minutes)
	case hours > 0:   return fmt.tprintf("%d h %d min", hours, minutes)
	case minutes > 0: return fmt.tprintf("%d min", minutes)
	}
	return fmt.tprintf("%d s", s)
}

// A graph's span in words, its points times the period: "60 seconds", "2 minutes", "2 min 30 s".
span_text :: proc(points, period_ms: int) -> string {
	s := points * period_ms / 1000
	switch {
	case s < 120:    return fmt.tprintf(i18n.tr(s, "%d second", "%d seconds"), s)
	case s % 60 == 0: return fmt.tprintf(i18n.tr(s / 60, "%d minute", "%d minutes"), s / 60)
	}
	return fmt.tprintf("%d min %d s", s / 60, s % 60)
}

// The processors a set holds, as runs: "0-3, 8, 10-15" ("none" for none).
cpu_list_text :: proc(cpus: []bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(cpus); {
		if !cpus[i] { i += 1; continue }
		j := i
		for j + 1 < len(cpus) && cpus[j + 1] { j += 1 }
		if strings.builder_len(b) > 0 { strings.write_string(&b, ", ") }
		if j > i { fmt.sbprintf(&b, "%d-%d", i, j) } else { fmt.sbprintf(&b, "%d", i) }
		i = j + 1
	}
	if strings.builder_len(b) == 0 { return i18n.tr("none") }
	return strings.to_string(b)
}
