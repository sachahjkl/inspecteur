package inspecteurtool

// logo: inspecteur's mark, drawn by the toolkit's paint package (the same bytes on every system). A magnifying glass
// held over a running machine: a metal ring around dark glass, a handle down to the right, and in the glass the line
// of a load graph, bright, with a soft area under it. Small sizes drop the area and the glint and draw a simpler,
// thicker line (detail_for), so the mark still reads at 16 px.
// assets/logo.png (1024 px), the sizes the program, its desktop entry and the site embed, and .project/image.png
// (inspecteurtool logo: the toolkit's logo command).

import paint "gt:paint"
import toolbox "gt:toolbox"

LOGO_DIR    :: "assets"
LOGO_MASTER :: 1024
LOGO_SIZES  :: [?]int{16, 24, 32, 48, 64, 128, 256, 512}
// The drawing's own units: a square of LOGO_UNITS, scaled to the canvas.
LOGO_UNITS  :: 512.0
// Small sizes are drawn from a master this many times larger, in one step of the cubic filter at most this factor.
LOGO_SHRINK_STEP :: 4

// The lens: its centre, the ring's outer radius and the glass's radius, in units.
LENS_X     :: 212.0
LENS_Y     :: 212.0
LENS_OUTER :: 168.0
LENS_INNER :: 132.0

// The colours.
RING_TOP     :: 0xF2F5F8
RING_BOTTOM  :: 0x8D9BAA
RING_EDGE    :: 0x3A4654
GLASS_CENTRE :: 0x1E5E93
GLASS_EDGE   :: 0x0B2238
LINE         :: 0x5BE7C4
HANDLE_TOP   :: 0x4A5868
HANDLE_END   :: 0x1C2530

// 2: everything (64 px and up); 1: the line and the area, no glint (32 to 48); 0: a simple thick line (16 to 24).
detail_for :: proc(size: int) -> int { return size <= 24 ? 0 : size <= 48 ? 1 : 2 }

@(private = "file")
circle :: proc(p: ^paint.Path, cx, cy, r: f32) { paint.ellipse(p, cx - r, cy - r, r * 2, r * 2) }

logo_draw :: proc(size: int, detail: int) -> paint.Canvas {
	c := paint.canvas_make(size, size)
	k := f32(size) / LOGO_UNITS
	c.transform = paint.scale(paint.IDENTITY, k, k)

	// the handle, under the ring: a thick bar with round ends, from the ring down to the bottom right corner
	handle: paint.Path
	defer paint.path_destroy(&handle)
	paint.move_to(&handle, 318, 318)
	paint.line_to(&handle, 456, 456)
	paint.stroke(&c, handle, {width = 74, cap = .Round}, paint.linear({318, 318}, {456, 456}, paint.hex(HANDLE_TOP), paint.hex(HANDLE_END)))

	// the glass: dark at its edge, lighter at its centre
	glass: paint.Path
	defer paint.path_destroy(&glass)
	circle(&glass, LENS_X, LENS_Y, LENS_INNER + 2)
	paint.fill(&c, glass, paint.radial({LENS_X - 30, LENS_Y - 40}, LENS_INNER * 1.25, paint.hex(GLASS_CENTRE), paint.hex(GLASS_EDGE)))

	// the load graph inside the glass: a line with an area under it, both cut to the glass
	paint.set_clip(&c, glass)
	points_full := [?][2]f32{{60, 252}, {110, 252}, {136, 226}, {160, 270}, {190, 150}, {222, 300}, {250, 196}, {276, 240}, {300, 220}, {364, 220}}
	points_small := [?][2]f32{{60, 252}, {162, 252}, {212, 136}, {262, 252}, {364, 252}}
	points := detail == 0 ? points_small[:] : points_full[:]
	if detail > 0 {
		area: paint.Path
		defer paint.path_destroy(&area)
		paint.move_to(&area, points[0].x, 400)
		for q in points { paint.line_to(&area, q.x, q.y) }
		paint.line_to(&area, points[len(points) - 1].x, 400)
		paint.close(&area)
		paint.fill(&c, area, paint.linear({0, 150}, {0, 380}, paint.hex(LINE, 110), paint.hex(LINE, 0)))
	}
	line: paint.Path
	defer paint.path_destroy(&line)
	paint.move_to(&line, points[0].x, points[0].y)
	for q in points[1:] { paint.line_to(&line, q.x, q.y) }
	paint.stroke(&c, line, {width = detail == 0 ? 44 : 20, join = .Round, cap = .Round}, paint.solid(paint.hex(LINE)))
	// a glint on the glass, top left
	if detail == 2 {
		glint: paint.Path
		defer paint.path_destroy(&glint)
		paint.arc(&glint, LENS_X - LENS_INNER + 26, LENS_Y - LENS_INNER + 26, (LENS_INNER - 26) * 2, (LENS_INNER - 26) * 2, 200, 60)
		paint.stroke(&c, glint, {width = 14, cap = .Round}, paint.solid(paint.hex(0xFFFFFF, 90)))
	}
	paint.reset_clip(&c)

	// the ring: metal, light at the top, with a dark edge inside and out
	ring: paint.Path
	defer paint.path_destroy(&ring)
	circle(&ring, LENS_X, LENS_Y, LENS_OUTER)
	circle(&ring, LENS_X, LENS_Y, LENS_INNER)
	paint.fill(&c, ring, paint.linear({0, LENS_Y - LENS_OUTER}, {0, LENS_Y + LENS_OUTER}, paint.hex(RING_TOP), paint.hex(RING_BOTTOM)), .Even_Odd)
	edges: paint.Path
	defer paint.path_destroy(&edges)
	circle(&edges, LENS_X, LENS_Y, LENS_OUTER - 4)
	circle(&edges, LENS_X, LENS_Y, LENS_INNER + 4)
	paint.stroke(&c, edges, {width = detail == 0 ? 20 : 8}, paint.solid(paint.hex(RING_EDGE, 230)))
	return c
}

// The picture at `size`: drawn large, then shrunk in steps the cubic filter keeps clean.
logo_render :: proc(size: int) -> paint.Canvas {
	n := size
	for n < LOGO_MASTER { n *= LOGO_SHRINK_STEP }
	c := logo_draw(n, detail_for(size))
	for n > size {
		next := max(n / LOGO_SHRINK_STEP, size)
		small := paint.resize(c, next, next)
		paint.canvas_destroy(&c)
		c, n = small, next
	}
	return c
}

// What the logo command writes (toolbox.write_logo): assets/logo.png, the sizes, .project/image.png.
@(rodata)
LOGO_SIZE_LIST := LOGO_SIZES

logo :: proc() -> toolbox.Logo {
	return {
		render = proc(size: int, user: rawptr) -> paint.Canvas { return logo_render(size) },
		dir = LOGO_DIR, master = LOGO_MASTER, sizes = LOGO_SIZE_LIST[:], project_image = true,
	}
}
