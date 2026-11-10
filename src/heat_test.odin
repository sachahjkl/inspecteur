package inspecteur

import "core:testing"
import "gt:ui"

@(private = "file") DARK_PAGE  :: ui.Color{0.10, 0.10, 0.11, 1}
@(private = "file") LIGHT_PAGE :: ui.Color{0.97, 0.97, 0.97, 1}

@(test)
heat_goes_green_yellow_red_with_a_text_that_reads :: proc(t: ^testing.T) {
	// a light load: green, the most of its hue in green
	bg, fg := heat_colors(0.1, DARK_PAGE)
	testing.expect(t, bg.g > bg.r && bg.g > bg.b, "a light load is green")
	// the middle: yellow (red and green high, blue low), which takes dark text even on a dark page
	bg, fg = heat_colors(0.5, DARK_PAGE)
	testing.expect(t, bg.r > 0.8 && bg.g > 0.6 && bg.b < 0.3, "half way is yellow")
	testing.expect_value(t, fg, HEAT_TEXT_DARK)
	// full: red, with light text on either page
	bg, fg = heat_colors(1, DARK_PAGE)
	testing.expect(t, bg.r > 0.8 && bg.g < 0.3, "full is red")
	testing.expect_value(t, fg, HEAT_TEXT_LIGHT)
	_, fg = heat_colors(1, LIGHT_PAGE)
	testing.expect_value(t, fg, HEAT_TEXT_LIGHT)
	// more than full stays red; the opacity grows with the load
	over, _ := heat_colors(3, DARK_PAGE)
	full, _ := heat_colors(1, DARK_PAGE)
	testing.expect_value(t, over, full)
	low, _ := heat_colors(0.1, DARK_PAGE)
	testing.expect(t, low.a < full.a, "a lighter load is fainter")
}
