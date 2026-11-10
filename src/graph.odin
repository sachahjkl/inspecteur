package inspecteur

// A graph of the last HISTORY_POINTS values of one to three histories: the newest at the right edge, each series an area
// filled from its line down (its colour, fading to the bottom) under its line. A graph has grid lines and a frame
// (`grid`); a sparkline (the Performance section's list) has neither. The colours are the theme's: the hues of its
// palette for the series (hue), its border for the lines.

import "core:math"
import "gt:draw"
import "gt:ui"

GRAPH_COLUMNS :: 10   // vertical grid lines: one each 6 s at the default period
GRAPH_ROWS    :: 4
GRAPH_FILL_TOP    :: 0.32   // the area's opacity under its line
GRAPH_FILL_BOTTOM :: 0.06   // and at the bottom
GRAPH_GRID_ALPHA  :: 0.55

Series :: struct {
	hist:  ^History,
	color: ui.Color,
	name:  string,   // in the graph's legend ("": none)
}

Graph_Draw :: struct {
	series: [3]Series,
	count:  int,
	top:    f32,   // the value at the top of the graph
	grid:   bool,
	line:   ui.Color,   // the grid's and the frame's
	scale:  f32,
}

// A graph in a box of the size `next` gives it. `top` 0: the largest value shown, rounded up (graph_top).
graph :: proc(id: string, series: []Series, top: f32 = 100, grid := true) -> ^ui.Box {
	d := ui.frame_new(Graph_Draw)
	d.count = min(len(series), len(d.series))
	copy(d.series[:], series)
	d.top = top
	if top <= 0 {
		m: f32
		for s in series { m = max(m, history_max(s.hist)) }
		d.top = graph_top(m)
	}
	d.grid = grid
	d.line = ui.color("border")
	d.scale = ui.scale()
	return ui.custom(id, graph_draw, d)
}

// A round value at or above `v` (1, 2 or 5 times a power of ten; at least 1): the top of a graph of rates.
graph_top :: proc(v: f32) -> f32 {
	if v <= 1 { return 1 }
	p := math.pow(10, math.floor(math.log10(v)))
	for k in ([]f32{1, 2, 5, 10}) { if v <= k * p { return k * p } }
	return 10 * p
}

@(private = "file")
graph_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Graph_Draw)(user)
	r := b.rect
	w, h := r.max.x - r.min.x, r.max.y - r.min.y
	if w <= 2 || h <= 2 { return }
	px := max(1, math.round(d.scale))
	if d.grid {
		grid := d.line
		grid.a *= GRAPH_GRID_ALPHA
		for i in 1 ..< GRAPH_COLUMNS {
			x := math.round(r.min.x + w * f32(i) / GRAPH_COLUMNS)
			draw.rect(dc, {{x, r.min.y}, {x + px, r.max.y}}, grid)
		}
		for i in 1 ..< GRAPH_ROWS {
			y := math.round(r.min.y + h * f32(i) / GRAPH_ROWS)
			draw.rect(dc, {{r.min.x, y}, {r.max.x, y + px}}, grid)
		}
	}
	step := w / f32(HISTORY_POINTS - 1)
	points := make([dynamic]ui.Vec2, 0, HISTORY_POINTS + 2, context.temp_allocator)
	for s in d.series[:d.count] {
		n := s.hist.count
		if n < 2 { continue }
		clear(&points)
		for i in 0 ..< n {
			v := clamp(history_at(s.hist, i) / max(d.top, 1e-6), 0, 1)
			append(&points, ui.Vec2{r.max.x - f32(n - 1 - i) * step, r.max.y - v * (h - px)})
		}
		// the area: the line, then down to the bottom; a gradient from under the line to the bottom
		line_len := len(points)
		append(&points, ui.Vec2{points[line_len - 1].x, r.max.y}, ui.Vec2{points[0].x, r.max.y})
		top_c, bottom_c := s.color, s.color
		top_c.a *= GRAPH_FILL_TOP
		bottom_c.a *= GRAPH_FILL_BOTTOM
		draw.push_clip_polygon(dc, points[:])
		draw.rect_corners(dc, {{points[0].x, r.min.y}, r.max}, {top_c, bottom_c, top_c, bottom_c}, {})
		draw.pop_clip(dc)
		draw.polyline(dc, points[:line_len], d.grid ? 1.5 * d.scale : 1.2 * d.scale, s.color)
	}
	if d.grid { draw.rect(dc, r, d.line, border = px) }
}

// The theme's hue `i` (0 accent, 1 blue, 2 purple, 3 green, 4 yellow, 5 red, 6 cyan, 7 rose) in the version shown.
hue :: proc(app: ^App, i: int) -> ui.Color {
	c, _ := ui.theme_version(app.theme_shown.def, app.theme_shown.light)
	return draw.hex(c.hues[i])
}
