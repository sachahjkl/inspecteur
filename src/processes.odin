package inspecteur

// The rows of the Processes tab, made again after each sample and each change of the sort, the filter or a group:
//
//   Apps (n)                          a section: the processes of an app, one group each
//     Firefox (12)                    the group: the sum of its processes; open, its processes under it
//       firefox, Web Content...
//   Background processes (n)          a section: every other process, one row each
//
// A group's processes are the app's process (the highest one of that app in its line of parents) and every process
// under it, unless one of them is another app (a browser started from a terminal is the browser's group). Sorting
// orders the groups among themselves, the processes of a group, and the background processes.

import "core:slice"
import "core:strconv"
import "core:strings"
import "gt:ascii"
import "gt:ui"

Column :: enum u8 { Name, PID, PPID, User, State, Nice, CPU, Memory, GPU_Memory, Read, Write, Threads, Started, Command, Executable }

COLUMN_NAMES := [Column]string{
	.Name = "Name", .PID = "PID", .PPID = "Parent PID", .User = "User", .State = "State", .Nice = "Nice", .CPU = "CPU",
	.Memory = "Memory", .GPU_Memory = "GPU memory", .Read = "Disk read", .Write = "Disk write", .Threads = "Threads",
	.Started = "Started", .Command = "Command line", .Executable = "Executable",
}
// The names in the preferences (processes.columns, processes.widths, processes.sort).
COLUMN_KEYS := [Column]string{
	.Name = "name", .PID = "pid", .PPID = "ppid", .User = "user", .State = "state", .Nice = "nice", .CPU = "cpu",
	.Memory = "memory", .GPU_Memory = "gpu_memory", .Read = "read", .Write = "write", .Threads = "threads",
	.Started = "started", .Command = "command", .Executable = "executable",
}
// The columns of text, on the left of their cells; numbers are on the right.
COLUMN_TEXT :: bit_set[Column]{.Name, .User, .State, .Started, .Command, .Executable}
// Each column's width when none was chosen, in ems (Name takes the room the others leave).
COLUMN_DEFAULT_EM := [Column]f32{
	.Name = 0, .PID = 5.5, .PPID = 6.5, .User = 6.5, .State = 7, .Nice = 4.5, .CPU = 5.5, .Memory = 6.5, .GPU_Memory = 7,
	.Read = 7, .Write = 7, .Threads = 5.5, .Started = 9.5, .Command = 22, .Executable = 18,
}

column_of :: proc(key: string) -> (c: Column, ok: bool) {
	for k, col in COLUMN_KEYS { if k == key { return col, true } }
	return
}

Group :: struct {
	root:    int,     // one of the app's processes (group_roots: all of them), in the sampler's list
	entry:   int,     // its desktop entry
	key:     u64,     // its identity (its entry)
	first, count: int,   // its processes: Table.members[first:first + count]
	cpu:     f32,
	rss:     u64,
	gpu_mem: u64,
	read_rate, write_rate: f64,
	threads: i32,
}

Row_Kind :: enum u8 { Section, App, Process }

Row :: struct {
	kind:  Row_Kind,
	depth: u8,     // 1: a process of a group
	index: i32,    // Section: 0 apps, 1 background; App: the group; Process: the process
}

Table :: struct {
	groups:     [dynamic]Group,
	members:    [dynamic]int,
	background: [dynamic]int,
	owner:      [dynamic]int,    // each process's app process (-1: none), as table_group found them
	rows:       [dynamic]Row,
	ids:        [dynamic]u64,    // each row's identity, stable across samples (the list's row keys, the selection)
	selectable: [dynamic]bool,
	shown_apps, shown_background: int,   // the rows each section counts (the filter's matches)
	expanded:   map[u64]bool,    // the groups open, by key
	columns:    [len(Column)]ui.Table_Column,   // what the layout's columns are (table_columns_init)
	layout:     ui.Table_Layout,  // the columns shown, their widths, the sort (the header edits it; settings.odin saves it)
	query:      string,          // the filter, in lower case (owned)
}

// The columns of the table for the toolkit's header: texts at the left, numbers at the right; a pid and a nice value
// sorted from the lowest at the first click, an amount from the largest.
table_columns_init :: proc(t: ^Table) {
	for c in Column {
		t.columns[int(c)] = {
			title = COLUMN_NAMES[c], width = COLUMN_DEFAULT_EM[c], number = c not_in COLUMN_TEXT,
			low_first = c == .PID || c == .PPID || c == .Nice, hidden = c not_in DEFAULT_COLUMNS,
		}
	}
	ui.table_layout_init(&t.layout, t.columns[:])
}

// The sort's column.
table_sort :: proc(t: ^Table) -> Column { return Column(t.layout.sort) }

SECTION_IDS :: [2]u64{0x5ec7_0000_0000_0001, 0x5ec7_0000_0000_0002}
APP_ID_MARK :: u64(1) << 63

proc_key :: proc(p: Proc) -> u64 { return u64(u32(p.pid)) << 32 | (p.start & 0xffff_ffff) }

table_destroy :: proc(t: ^Table) {
	delete(t.groups)
	delete(t.members)
	delete(t.background)
	delete(t.owner)
	delete(t.rows)
	delete(t.ids)
	delete(t.selectable)
	delete(t.expanded)
	delete(t.query)
	ui.table_layout_destroy(&t.layout)
}

// Groups the processes into apps and the rest (after a sample).
table_group :: proc(t: ^Table, procs: []Proc) {
	clear(&t.groups)
	clear(&t.members)
	clear(&t.background)
	n := len(procs)
	at := make(map[i32]int, n, context.temp_allocator)
	for p, i in procs { at[p.pid] = i }
	parent :: proc(at: ^map[i32]int, p: Proc) -> int {
		if p.ppid == p.pid { return -1 }
		if i, ok := at[p.ppid]; ok { return i }
		return -1
	}
	// owner[i]: the root process of i's app, -1 for none; -2 not yet known. Each line of parents is walked once.
	owner := make([]int, n, context.temp_allocator)
	slice.fill(owner, -2)
	path := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< n {
		clear(&path)
		q := i
		found := -1
		for q >= 0 && len(path) <= n {
			if owner[q] != -2 { found = owner[q]; break }
			append(&path, q)
			if procs[q].entry >= 0 {
				// the highest process of the same app above it
				root := q
				for up := parent(&at, procs[root]); up >= 0 && procs[up].entry == procs[q].entry && root != up; up = parent(&at, procs[root]) { root = up }
				found = root
				break
			}
			q = parent(&at, procs[q])
		}
		for k in path { owner[k] = found }
	}
	group_of := make(map[int]int, 64, context.temp_allocator)   // entry -> group
	counts := make([dynamic]int, context.temp_allocator)
	for o, i in owner {
		if o < 0 { append(&t.background, i); continue }
		e := procs[o].entry
		if _, ok := group_of[e]; !ok {
			// (the first app process met stands for the group in the PID and User columns)
			group_of[e] = len(t.groups)
			append(&t.groups, Group{root = o, entry = e, key = u64(e) | APP_ID_MARK})
			append(&counts, 0)
		}
		counts[group_of[e]] += 1
	}
	// the members, group after group
	first := 0
	for &g, k in t.groups { g.first = first; first += counts[k] }
	resize(&t.members, first)
	fill := make([]int, len(t.groups), context.temp_allocator)
	for o, i in owner {
		if o < 0 { continue }
		k := group_of[procs[o].entry]
		g := &t.groups[k]
		t.members[g.first + fill[k]] = i
		fill[k] += 1
		p := procs[i]
		g.cpu += p.cpu
		g.rss += p.rss
		g.gpu_mem += p.gpu_mem
		g.read_rate += p.read_rate
		g.write_rate += p.write_rate
		g.threads += p.threads
	}
	for &g, k in t.groups { g.count = fill[k] }
	resize(&t.owner, n)
	copy(t.owner[:], owner)
}

// The app's processes of a group: each of its members that is the highest of its app in its line of parents (the
// processes an End task on the group signals; the others are theirs).
group_roots :: proc(t: ^Table, g: Group, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for m in t.members[g.first:][:g.count] { if t.owner[m] == m { append(&out, m) } }
	return out[:]
}

// Whether a process passes the filter: its name or command line holds the query, or its pid starts with it.
proc_matches :: proc(p: Proc, query: string) -> bool {
	if query == "" { return true }
	if strings.contains(p.search, query) { return true }
	buf: [16]u8
	return strings.has_prefix(strconv.write_int(buf[:], i64(p.pid), 10), query)
}

// The rows, from the groups: sorted, filtered, groups open or closed.
table_rows :: proc(t: ^Table, s: ^Sampler, c: ^Catalog) {
	clear(&t.rows)
	clear(&t.ids)
	clear(&t.selectable)
	procs := s.procs[:]
	q := t.query
	add :: proc(t: ^Table, r: Row, id: u64, selectable: bool) {
		append(&t.rows, r)
		append(&t.ids, id)
		append(&t.selectable, selectable)
	}

	// the groups that pass, and which of their processes
	order := make([dynamic]Sort_Item, context.temp_allocator)
	for g, k in t.groups {
		name := c.entries[g.entry].name
		name_hit := q == "" || strings.contains(strings.to_lower(name, context.temp_allocator), q)
		member_hit := false
		if !name_hit { for m in t.members[g.first:][:g.count] { if proc_matches(procs[m], q) { member_hit = true; break } } }
		if !name_hit && !member_hit { continue }
		append(&order, sort_item_group(t, s, g, k, name))
	}
	sort_items(order[:], t.layout.descending)
	t.shown_apps = len(order)
	if len(order) > 0 {
		add(t, {kind = .Section, index = 0}, SECTION_IDS[0], false)
		members := make([dynamic]Sort_Item, context.temp_allocator)
		for it in order {
			g := t.groups[it.index]
			add(t, {kind = .App, index = i32(it.index)}, g.key, true)
			// open: asked, or the filter found some of its processes
			open := t.expanded[g.key] || q != ""
			if !open { continue }
			clear(&members)
			for m in t.members[g.first:][:g.count] {
				if q == "" || proc_matches(procs[m], q) { append(&members, sort_item_proc(t, s, m)) }
			}
			sort_items(members[:], t.layout.descending)
			for m in members { add(t, {kind = .Process, depth = 1, index = i32(m.index)}, proc_key(procs[m.index]), true) }
		}
	}

	clear(&order)
	for i in t.background {
		if proc_matches(procs[i], q) { append(&order, sort_item_proc(t, s, i)) }
	}
	sort_items(order[:], t.layout.descending)
	t.shown_background = len(order)
	if len(order) > 0 {
		add(t, {kind = .Section, index = 1}, SECTION_IDS[1], false)
		for it in order { add(t, {kind = .Process, index = i32(it.index)}, proc_key(procs[it.index]), true) }
	}
}

// What a row is sorted by: a number or a text; ties go by pid.
@(private = "file")
Sort_Item :: struct {
	num:   f64,
	text:  string,
	pid:   i32,
	index: int,
}

@(private = "file")
sort_item_proc :: proc(t: ^Table, s: ^Sampler, i: int) -> Sort_Item {
	p := &s.procs[i]
	it := Sort_Item{pid = p.pid, index = i}
	sort_value(&it, table_sort(t), s, p)
	return it
}

// A group sorts by its sums (CPU, memory, disk, threads), by its app's name, else by its first app process.
@(private = "file")
sort_item_group :: proc(t: ^Table, s: ^Sampler, g: Group, k: int, name: string) -> Sort_Item {
	root := &s.procs[g.root]
	it := Sort_Item{pid = root.pid, index = k}
	#partial switch table_sort(t) {
	case .Name:       it.text = name
	case .CPU:        it.num = f64(g.cpu)
	case .Memory:     it.num = f64(g.rss)
	case .GPU_Memory: it.num = f64(g.gpu_mem)
	case .Read:       it.num = g.read_rate
	case .Write:      it.num = g.write_rate
	case .Threads:    it.num = f64(g.threads)
	case:             sort_value(&it, table_sort(t), s, root)
	}
	return it
}

@(private = "file")
sort_value :: proc(it: ^Sort_Item, c: Column, s: ^Sampler, p: ^Proc) {
	switch c {
	case .Name:       it.text = p.name
	case .PID:        it.num = f64(p.pid)
	case .PPID:       it.num = f64(p.ppid)
	case .User:       it.text = user_name(s, p.uid)
	case .State:      it.text = state_text(p.state)
	case .Nice:       it.num = f64(p.nice)
	case .CPU:        it.num = f64(p.cpu)
	case .Memory:     it.num = f64(p.rss)
	case .GPU_Memory: it.num = f64(p.gpu_mem)
	case .Read:       it.num = p.read_rate
	case .Write:      it.num = p.write_rate
	case .Threads:    it.num = f64(p.threads)
	case .Started:    it.num = f64(p.start)
	case .Command:    it.text = p.cmdline
	case .Executable: it.text = p.exe
	}
}

// A process's state as words (the letter of /proc/<pid>/stat).
state_text :: proc(state: u8) -> string {
	switch state {
	case 'R': return "Running"
	case 'S': return "Sleeping"
	case 'D': return "Disk wait"
	case 'T': return "Suspended"
	case 't': return "Traced"
	case 'Z': return "Zombie"
	case 'X': return "Dead"
	case 'I': return "Idle"
	}
	return "?"
}

@(private = "file")
sort_items :: proc(items: []Sort_Item, descending: bool) {
	slice.sort_by(items, proc(a, b: Sort_Item) -> bool {
		if a.text != b.text {
			c := ascii.compare_fold(a.text, b.text)
			if c != 0 { return c < 0 }
		}
		if a.num != b.num { return a.num < b.num }
		return a.pid < b.pid
	})
	if descending { slice.reverse(items) }
}

