package inspecteur

import "core:testing"
import "gt:draw"

// (its text is the toolkit's ui.ink_on, tested there: the theme's ink that reads on it)
@(test)
heat_goes_green_yellow_red :: proc(t: ^testing.T) {
	DARK_PAGE := draw.srgb(0.10, 0.10, 0.11, 1)
	LIGHT_PAGE := draw.srgb(0.97, 0.97, 0.97, 1)
	// a light load: green, the most of its colour in green
	bg, _ := heat_colors(0.1, DARK_PAGE)
	testing.expect(t, bg.g > bg.r && bg.g > bg.b, "a light load is green")
	// a third of the way: yellow (red and green high, blue low)
	bg, _ = heat_colors(1.0 / 3, DARK_PAGE)
	testing.expect(t, bg.r > 0.3 && bg.g > 0.2 && bg.b < 0.05, "a third of the way is yellow")
	// full: red
	bg, _ = heat_colors(1, DARK_PAGE)
	testing.expect(t, bg.r > 0.3 && bg.g < 0.05, "full is red")
	// more than full stays red; a lighter load is nearer the page
	over, _ := heat_colors(3, DARK_PAGE)
	full, border := heat_colors(1, DARK_PAGE)
	testing.expect_value(t, over, full)
	low, _ := heat_colors(0.1, LIGHT_PAGE)
	testing.expect(t, low.r > 0.3 && low.b > 0.3 && low.a == 1, "a lighter load is a pale green on a light page, opaque")
	// the outline: the red, darker, opaque
	testing.expect(t, border.a == 1 && border.r < full.r && border.r > border.g, "the outline is a darker red")
}
