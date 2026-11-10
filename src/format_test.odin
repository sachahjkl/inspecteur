package inspecteur

import "core:testing"

@(test)
numbers_read_as_words :: proc(t: ^testing.T) {
	testing.expect_value(t, duration_words(3 * 86400 + 4 * 3600 + 12 * 60 + 5), "3 days, 4 h 12 min")
	testing.expect_value(t, duration_words(86400), "1 day, 0 h 0 min")
	testing.expect_value(t, duration_words(10 * 3600 + 47 * 60), "10 h 47 min")
	testing.expect_value(t, duration_words(300), "5 min")
	testing.expect_value(t, duration_words(40), "40 s")
	testing.expect_value(t, cpu_time_text(12_340_000_000), "12.34 s")
	testing.expect_value(t, cpu_time_text(185_200_000_000), "3:05.20")
	testing.expect_value(t, cpu_time_text(7385 * 1_000_000_000), "2:03:05")
	testing.expect_value(t, mhz_text(0), "–")
	testing.expect_value(t, mhz_text(800), "800 MHz")
	testing.expect_value(t, mhz_text(4742), "4.74 GHz")
	testing.expect_value(t, bits_text(125), "1 kbit/s")
	testing.expect_value(t, bits_text(1_550_000), "12.4 Mbit/s")
	testing.expect_value(t, bits_text(0), "0 bit/s")
	testing.expect_value(t, uptime_text(3 * 86400 + 4 * 3600 + 12 * 60 + 9), "3:04:12:09")
	testing.expect_value(t, count_text(1, "app", "apps"), "1 app")
	testing.expect_value(t, count_text(3, "app", "apps"), "3 apps")
}

// A graph's span follows the period of its readings (processes.refresh_ms, GPU_PERIOD).
@(test)
a_span_follows_the_period :: proc(t: ^testing.T) {
	testing.expect_value(t, span_text(60, 1000), "60 seconds")
	testing.expect_value(t, span_text(60, 2000), "2 minutes")
	testing.expect_value(t, span_text(60, 250), "15 seconds")
	testing.expect_value(t, span_text(60, 2500), "2 min 30 s")
	testing.expect_value(t, span_text(60, 10_000), "10 minutes")
}
