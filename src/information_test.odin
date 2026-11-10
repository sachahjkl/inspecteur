package inspecteur

import "core:testing"

@(test)
a_duration_reads_in_words :: proc(t: ^testing.T) {
	testing.expect_value(t, duration_words(3 * 86400 + 4 * 3600 + 12 * 60 + 5), "3 days, 4 h 12 min")
	testing.expect_value(t, duration_words(86400), "1 day, 0 h 0 min")
	testing.expect_value(t, duration_words(10 * 3600 + 47 * 60), "10 h 47 min")
	testing.expect_value(t, duration_words(300), "5 min")
}
