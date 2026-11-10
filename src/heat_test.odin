package inspecteur

import "core:testing"
import "gt:draw"
import "gt:ui"

@(test)
heat_goes_green_yellow_red_with_a_text_that_reads :: proc(t: ^testing.T) {
	DARK_PAGE := draw.srgb(0.10, 0.10, 0.11, 1)
	LIGHT_PAGE := draw.srgb(0.97, 0.97, 0.97, 1)
	// a light load: green, the most of its colour in green
	bg, fg, _ := heat_colors(0.1, DARK_PAGE)
	testing.expect(t, bg.g > bg.r && bg.g > bg.b, "a light load is green")
	// a third of the way: yellow (red and green high, blue low), which takes dark text even on a dark page
	bg, fg, _ = heat_colors(1.0 / 3, DARK_PAGE)
	testing.expect(t, bg.r > 0.3 && bg.g > 0.2 && bg.b < 0.05, "a third of the way is yellow")
	testing.expect_value(t, fg, HEAT_TEXT_DARK)
	// full: red, with light text on either page
	bg, fg, _ = heat_colors(1, DARK_PAGE)
	testing.expect(t, bg.r > 0.3 && bg.g < 0.05, "full is red")
	testing.expect_value(t, fg, HEAT_TEXT_LIGHT)
	_, fg, _ = heat_colors(1, LIGHT_PAGE)
	testing.expect_value(t, fg, HEAT_TEXT_LIGHT)
	// more than full stays red; a lighter load is nearer the page
	over, _, _ := heat_colors(3, DARK_PAGE)
	full, _, border := heat_colors(1, DARK_PAGE)
	testing.expect_value(t, over, full)
	low, _, _ := heat_colors(0.1, LIGHT_PAGE)
	testing.expect(t, low.r > 0.3 && low.b > 0.3 && low.a == 1, "a lighter load is a pale green on a light page, opaque")
	// the outline: the red, darker, opaque
	testing.expect(t, border.a == 1 && border.r < full.r && border.r > border.g, "the outline is a darker red")
	_ = ui.Color{}
}
