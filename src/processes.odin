package inspecteur

// The rows of the Processes tab, made again after each sample and each change of the sort, the filter or a group:
//
//   Apps (n)                          a section: the processes of an app, one group each
//     Firefox (12)                    the group: the sum of its processes; open, its processes under it
//       firefox, Web Content...
//   Background processes (n)          a section: every other process, one row each
//
// Pinned apps and processes (Alt+P, processes.pinned, by name) are in a section of their own above the others, sorted
// among themselves, whatever the sort.
//
// A group's processes are the app's process (the highest one of that app in its line of parents) and every process
// under it, unless one of them is another app (a browser started from a terminal is the browser's group). Sorting
// orders the groups among themselves, the processes of a group, and the background processes.

import "core:slice"
import "core:strconv"
import "core:strings"
import "gt:ascii"
import "gt:ui"
import i18n "gt:i18n"

// Memory is a process's private memory: the pages that are its own. The resident memory counts the pages it shares with
// others too (its libraries, shared memory): summed over a group, it would count them once per process.
Column :: enum u8 { Name, PID, PPID, User, State, Nice, CPU, CPU_Graph, Memory, Resident, GPU, GPU_Memory, Read, Write, Threads, Started, Command, Executable }

COLUMN_NAMES := [Column]string{
	.Name = i18n.later("Name"), .PID = i18n.later("PID"), .PPID = i18n.later("Parent PID"), .User = i18n.later("User"), .State = i18n.later("State"), .Nice = PRIORITY_COLUMN, .CPU = i18n.later("CPU"), .CPU_Graph = i18n.later("CPU, 30 s"),
	.Memory = i18n.later("Private memory"), .Resident = i18n.later("Resident"), .GPU = i18n.later("GPU"), .GPU_Memory = i18n.later("GPU memory"), .Read = i18n.later("Disk read"), .Write = i18n.later("Disk write"),
	.Threads = i18n.later("Threads"), .Started = i18n.later("Started"), .Command = i18n.later("Command line"), .Executable = i18n.later("Executable"),
}
// The names in the preferences (processes.columns, processes.widths, processes.sort).
COLUMN_KEYS := [Column]string{
	.Name = "name", .PID = "pid", .PPID = "ppid", .User = "user", .State = "state", .Nice = "nice", .CPU = "cpu", .CPU_Graph = "cpu_graph",
	.Memory = "memory", .Resident = "resident", .GPU = "gpu", .GPU_Memory = "gpu_memory", .Read = "read", .Write = "write",
	.Threads = "threads", .Started = "started", .Command = "command", .Executable = "executable",
}
// The columns of text, on the left of their cells; numbers are on the right.
COLUMN_TEXT :: bit_set[Column]{.Name, .User, .State, .Started, .Command, .Executable}
// Each column's width when none was chosen, in ems (Name takes the room the others leave).
COLUMN_DEFAULT_EM := [Column]f32{
	.Name = 0, .PID = 5.5, .PPID = 6.5, .User = 6.5, .State = 7, .Nice = 4.5, .CPU = 5.5, .CPU_Graph = 6.5, .Memory = 8.5, .Resident = 7,
	.GPU = 5.5, .GPU_Memory = 7, .Read = 7, .Write = 7, .Threads = 5.5, .Started = 9.5, .Command = 22, .Executable = 18,
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
	private: u64,    // the sum of its processes' private memory (their resident memory would count shared pages again)
	resident: u64,
	gpu:     f32,
	gpu_mem: u64,
	read_rate, write_rate: f64,
	threads: i32,
}

Row_Kind :: enum u8 { Section, App, Process }

Row :: struct {
	kind:   Row_Kind,
	depth:  u8,     // 1: a process of a group; in the tree, the process's depth under its first parent shown
	branch: bool,   // in the tree: processes are under it (shown, or closed away)
	index:  i32,    // Section: 0 apps, 1 background; App: the group; Process: the process
}

Table :: struct {
	groups:     [dynamic]Group,
	members:    [dynamic]int,
	background: [dynamic]int,
	owner:      [dynamic]int,    // each process's app process (-1: none), as table_group found them
	rows:       [dynamic]Row,
	ids:        [dynamic]u64,    // each row's identity, stable across samples (the list's row keys, the selection)
	prev_ids:   [dynamic]u64,    // last built ids: ids_version bumps only when row order or membership changes
	ids_version: u64,            // passed to ui.vlist so unchanged row orders skip Fenwick rebuilds
	selectable: [dynamic]bool,
	at:         map[i32]int,     // pid -> index in sampler.procs, reused across samples
	group_of:   map[int]int,     // desktop entry -> group index, reused across samples
	path:       [dynamic]int,    // parent-chain scratch buffer reused by table_group
	shown_apps, shown_background, shown_pinned: int,   // the rows each section counts (the filter's matches)
	pinned:     map[string]bool, // the names pinned (an app's or a process's), from processes.pinned (owned keys)
	expanded:   map[u64]bool,    // the groups open, by key
	tree:       bool,            // every process under its parent (processes.view = tree), not apps and background
	collapsed:  map[u64]bool,    // in the tree, the processes whose children are closed away, by key
	shown_tree: int,             // in the tree, the processes the filter shows
	columns:    [len(Column)]ui.Table_Column,   // what the layout's columns are (table_columns_init)
	layout:     ui.Table_Layout,  // the columns shown, their widths, the sort (the header edits it; settings.odin saves it)
	query:      string,          // the filter, in lower case (owned)
}

// The columns of the table for the toolkit's header: texts at the left, numbers at the right; a pid and a nice value
// sorted from the lowest at the first click, an amount from the largest. Those shown by default are processes.columns'
// default (settings.odin).
table_columns_init :: proc(t: ^Table) {
	shown := columns_of(PREF_DEFS[PREF_COLUMNS].default.s)
	for c in Column {
		t.columns[int(c)] = {
			title = COLUMN_NAMES[c], width = COLUMN_DEFAULT_EM[c], number = c not_in COLUMN_TEXT,
			low_first = c == .PID || c == .PPID || c == .Nice, hidden = c != .Name && c not_in shown,
		}
	}
	ui.table_layout_init(&t.layout, t.columns[:])
}

// The columns a list of their keys names ("pid,user,cpu"); a key it does not know is left out.
columns_of :: proc(keys: string) -> (out: bit_set[Column]) {
	for key in strings.split(keys, ",", context.temp_allocator) {
		if c, ok := column_of(strings.trim_space(key)); ok { out += {c} }
	}
	return
}

// The sort's column.
// The sort's column; `sorted` false: none (the rows by PID, as they are read).
table_sort :: proc(t: ^Table) -> (c: Column, sorted: bool) {
	if t.layout.sort < 0 { return .Name, false }
	return Column(t.layout.sort), true
}

// Whether the active sort depends only on per-process facts that do not change between samples unless membership changes.
table_sort_static :: proc(t: ^Table) -> bool {
	c, sorted := table_sort(t)
	if !sorted { return true }
	#partial switch c {
	case .Name, .PID, .PPID, .User, .Started, .Command, .Executable: return true
	}
	return false
}

SECTION_IDS :: [3]u64{0x5ec7_0000_0000_0001, 0x5ec7_0000_0000_0002, 0x5ec7_0000_0000_0003}
// Section rows' index: Apps, Background processes, Pinned.
SECTION_APPS, SECTION_BACKGROUND, SECTION_PINNED :: 0, 1, 2
APP_ID_MARK :: u64(1) << 63

proc_key :: proc(p: Proc) -> u64 { return u64(u32(p.pid)) << 32 | (p.start & 0xffff_ffff) }

table_destroy :: proc(t: ^Table) {
	delete(t.groups)
	delete(t.members)
	delete(t.background)
	delete(t.owner)
	delete(t.rows)
	delete(t.ids)
	delete(t.prev_ids)
	delete(t.selectable)
	delete(t.at)
	delete(t.group_of)
	delete(t.path)
	delete(t.expanded)
	pins_clear(t)
	delete(t.pinned)
	delete(t.collapsed)
	delete(t.query)
	ui.table_layout_destroy(&t.layout)
}

// Groups the processes into apps and the rest (after a sample).
table_group :: proc(t: ^Table, procs: []Proc) {
	clear(&t.groups)
	clear(&t.members)
	clear(&t.background)
	n := len(procs)
	clear(&t.at)
	if cap(t.at) < n { reserve(&t.at, n) }
	for p, i in procs { t.at[p.pid] = i }
	// Prune dead keys from collapsed so long-running sessions with process churn stay bounded in memory.
	if len(t.collapsed) > 0 {
		dead := make([dynamic]u64, 0, min(len(t.collapsed), 32), context.temp_allocator)
		for k in t.collapsed {
			pid := i32(k >> 32)
			idx, ok := t.at[pid]
			if !ok || proc_key(procs[idx]) != k { append(&dead, k) }
		}
		for k in dead { delete_key(&t.collapsed, k) }
	}
	parent :: proc(at: ^map[i32]int, p: Proc) -> int {
		if p.ppid == p.pid { return -1 }
		if i, ok := at[p.ppid]; ok { return i }
		return -1
	}
	// owner[i]: the root process of i's app, -1 for none; -2 not yet known. Each line of parents is walked once.
	resize(&t.owner, n)
	slice.fill(t.owner[:], -2)
	for i in 0 ..< n {
		clear(&t.path)
		q := i
		found := -1
		for q >= 0 && len(t.path) <= n {
			if t.owner[q] != -2 { found = t.owner[q]; break }
			append(&t.path, q)
			if procs[q].entry >= 0 {
				// the highest process of the same app above it
				root := q
				for up := parent(&t.at, procs[root]); up >= 0 && procs[up].entry == procs[q].entry && root != up; up = parent(&t.at, procs[root]) { root = up }
				found = root
				break
			}
			q = parent(&t.at, procs[q])
		}
		for k in t.path { t.owner[k] = found }
	}
	clear(&t.group_of)
	counts := make([dynamic]int, 0, 64, context.temp_allocator)
	for o, i in t.owner {
		if o < 0 { append(&t.background, i); continue }
		e := procs[o].entry
		if _, ok := t.group_of[e]; !ok {
			// (the first app process met stands for the group in the PID and User columns)
			t.group_of[e] = len(t.groups)
			append(&t.groups, Group{root = o, entry = e, key = u64(e) | APP_ID_MARK})
			append(&counts, 0)
		}
		counts[t.group_of[e]] += 1
	}
	// the members, group after group
	first := 0
	for &g, k in t.groups { g.first = first; first += counts[k] }
	resize(&t.members, first)
	fill := make([]int, len(t.groups), context.temp_allocator)
	for o, i in t.owner {
		if o < 0 { continue }
		k := t.group_of[procs[o].entry]
		g := &t.groups[k]
		t.members[g.first + fill[k]] = i
		fill[k] += 1
		p := procs[i]
		g.cpu += p.cpu
		g.private += p.private
		g.resident += p.resident
		g.gpu += p.gpu
		g.gpu_mem += p.gpu_mem
		g.read_rate += p.read_rate
		g.write_rate += p.write_rate
		g.threads += p.threads
	}
	for &g, k in t.groups { g.count = fill[k] }
}

// The app's processes of a group: each of its members that is the highest of its app in its line of parents (the
// processes an End task on the group asks to end; the others are theirs, and end with them).
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

@(private = "file")
add_row :: proc(t: ^Table, r: Row, id: u64, selectable: bool) {
	append(&t.rows, r)
	append(&t.ids, id)
	append(&t.selectable, selectable)
}

// The deepest a tree's row is drawn (deeper processes are drawn at this depth: the name keeps some room).
TREE_DEPTH_MAX :: 24

// The rows of the tree: each process under its parent, the siblings sorted; a closed process's children not shown. A
// filter shows the processes it finds and their lines of parents (open, whatever was closed).
@(private = "file")
table_rows_tree :: proc(t: ^Table, s: ^Sampler) {
	procs := s.procs[:]
	q := t.query
	n := len(procs)
	clear(&t.at)
	if cap(t.at) < n { reserve(&t.at, n) }
	for p, i in procs { t.at[p.pid] = i }
	parent_idx := make([]int, n, context.temp_allocator)
	for p, i in procs {
		if p.ppid == p.pid {
			parent_idx[i] = -1
		} else if idx, ok := t.at[p.ppid]; ok {
			parent_idx[i] = idx
		} else {
			parent_idx[i] = -1
		}
	}
	// what the filter shows: the matches and their parents
	shown := make([]bool, n, context.temp_allocator)
	if q == "" {
		slice.fill(shown, true)
	} else {
		for p, i in procs {
			if !proc_matches(p, q) { continue }
			for k, steps := i, 0; k >= 0 && !shown[k] && steps <= n; steps += 1 {
				shown[k] = true
				k = parent_idx[k]
			}
		}
	}
	// Flat CSR storage for children avoids allocating one dynamic array per parent process.
	child_count := make([]int, n, context.temp_allocator)
	has_children := make([]bool, n, context.temp_allocator)
	root_count := 0
	t.shown_tree = 0
	for i in 0 ..< n {
		up := parent_idx[i]
		if up >= 0 { has_children[up] = true }
		if !shown[i] { continue }
		t.shown_tree += 1
		if up >= 0 && shown[up] { child_count[up] += 1 } else { root_count += 1 }
	}
	child_start := make([]int, n, context.temp_allocator)
	total_children := 0
	for i in 0 ..< n {
		child_start[i] = total_children
		total_children += child_count[i]
	}
	child_fill := make([]int, n, context.temp_allocator)
	children_flat := make([]Sort_Item, total_children, context.temp_allocator)
	roots := make([]Sort_Item, root_count, context.temp_allocator)
	root_fill := 0
	for i in 0 ..< n {
		if !shown[i] { continue }
		up := parent_idx[i]
		item := sort_item_proc(t, s, i)
		if up >= 0 && shown[up] {
			children_flat[child_start[up] + child_fill[up]] = item
			child_fill[up] += 1
		} else {
			roots[root_fill] = item
			root_fill += 1
		}
	}
	walk :: proc(t: ^Table, procs: []Proc, children_flat: []Sort_Item, child_start, child_count: []int, has_children: []bool, items: []Sort_Item, depth: int) {
		if len(items) > 1 { sort_items(items, t.layout.descending) }
		for it in items {
			p := procs[it.index]
			key := proc_key(p)
			add_row(t, {kind = .Process, depth = u8(min(depth, TREE_DEPTH_MAX)), branch = has_children[it.index], index = i32(it.index)}, key, true)
			if t.query == "" && t.collapsed[key] { continue }
			cnt := child_count[it.index]
			if cnt > 0 {
				walk(t, procs, children_flat, child_start, child_count, has_children, children_flat[child_start[it.index]:][:cnt], depth + 1)
			}
		}
	}
	walk(t, procs, children_flat, child_start, child_count, has_children, roots, 0)
}

// The rows, from the groups (or, in the tree, from each process's parent): sorted, filtered, groups open or closed.
table_rows :: proc(t: ^Table, s: ^Sampler, c: ^Catalog) {
	clear(&t.rows)
	clear(&t.ids)
	clear(&t.selectable)
	defer {
		if t.ids_version == 0 || !slice.simple_equal(t.ids[:], t.prev_ids[:]) {
			t.ids_version += 1
			resize(&t.prev_ids, len(t.ids))
			copy(t.prev_ids[:], t.ids[:])
		}
	}
	if t.tree { table_rows_tree(t, s); return }
	procs := s.procs[:]
	add :: add_row

	// pinned first, then the apps and the background processes that are not
	if len(t.pinned) > 0 {
		pinned_groups := groups_passing(t, s, c, true)
		pinned_procs := background_passing(t, s, true)
		t.shown_pinned = len(pinned_groups) + len(pinned_procs)
		if t.shown_pinned > 0 {
			add(t, {kind = .Section, index = SECTION_PINNED}, SECTION_IDS[SECTION_PINNED], false)
			add_groups(t, s, pinned_groups)
			for it in pinned_procs { add(t, {kind = .Process, index = i32(it.index)}, proc_key(procs[it.index]), true) }
		}
	} else {
		t.shown_pinned = 0
	}
	groups := groups_passing(t, s, c, false)
	t.shown_apps = len(groups)
	if len(groups) > 0 {
		add(t, {kind = .Section, index = SECTION_APPS}, SECTION_IDS[SECTION_APPS], false)
		add_groups(t, s, groups)
	}
	background := background_passing(t, s, false)
	t.shown_background = len(background)
	if len(background) > 0 {
		add(t, {kind = .Section, index = SECTION_BACKGROUND}, SECTION_IDS[SECTION_BACKGROUND], false)
		for it in background { add(t, {kind = .Process, index = i32(it.index)}, proc_key(procs[it.index]), true) }
	}
}

// The groups the filter passes whose app is pinned (or not), sorted.
@(private = "file")
groups_passing :: proc(t: ^Table, s: ^Sampler, c: ^Catalog, pinned: bool) -> []Sort_Item {
	procs := s.procs[:]
	q := t.query
	order := make([dynamic]Sort_Item, 0, len(t.groups), context.temp_allocator)
	for g, k in t.groups {
		e := c.entries[g.entry]
		if (len(t.pinned) > 0 && t.pinned[e.name]) != pinned { continue }
		name_hit := q == "" || strings.contains(e.name_lower, q)
		member_hit := false
		if !name_hit { for m in t.members[g.first:][:g.count] { if proc_matches(procs[m], q) { member_hit = true; break } } }
		if !name_hit && !member_hit { continue }
		append(&order, sort_item_group(t, s, g, k, e.name))
	}
	if len(order) > 1 { sort_items(order[:], t.layout.descending) }
	return order[:]
}

// The background processes the filter passes whose name is pinned (or not), sorted.
@(private = "file")
background_passing :: proc(t: ^Table, s: ^Sampler, pinned: bool) -> []Sort_Item {
	order := make([dynamic]Sort_Item, 0, len(t.background), context.temp_allocator)
	has_pinned := len(t.pinned) > 0
	for i in t.background {
		p := s.procs[i]
		if (has_pinned && t.pinned[p.name]) != pinned || !proc_matches(p, t.query) { continue }
		append(&order, sort_item_proc(t, s, i))
	}
	if len(order) > 1 { sort_items(order[:], t.layout.descending) }
	return order[:]
}

// The rows of groups: each group, and its processes when it is open (asked, or the filter found some of them).
@(private = "file")
add_groups :: proc(t: ^Table, s: ^Sampler, groups: []Sort_Item) {
	procs := s.procs[:]
	q := t.query
	members := make([dynamic]Sort_Item, context.temp_allocator)
	for it in groups {
		g := t.groups[it.index]
		add_row(t, {kind = .App, index = i32(it.index)}, g.key, true)
		if !(t.expanded[g.key] || q != "") { continue }
		clear(&members)
		for m in t.members[g.first:][:g.count] {
			if q == "" || proc_matches(procs[m], q) { append(&members, sort_item_proc(t, s, m)) }
		}
		sort_items(members[:], t.layout.descending)
		for m in members { add_row(t, {kind = .Process, depth = 1, index = i32(m.index)}, proc_key(procs[m.index]), true) }
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
	if c, sorted := table_sort(t); sorted { sort_value(&it, c, s, p) }
	return it
}

// A group sorts by its sums (CPU, memory, disk, threads), by its app's name, else by its first app process.
@(private = "file")
sort_item_group :: proc(t: ^Table, s: ^Sampler, g: Group, k: int, name: string) -> Sort_Item {
	root := &s.procs[g.root]
	it := Sort_Item{pid = root.pid, index = k}
	sort, sorted := table_sort(t)
	if !sorted { return it }   // (by its first process's PID)
	#partial switch sort {
	case .Name:       it.text = name
	case .CPU:        it.num = f64(g.cpu)
	case .CPU_Graph:  for m in t.members[g.first:][:g.count] { it.num += f64(cpu_recent(&s.procs[m])) }
	case .Memory:     it.num = f64(g.private)
	case .Resident:   it.num = f64(g.resident)
	case .GPU:        it.num = f64(g.gpu)
	case .GPU_Memory: it.num = f64(g.gpu_mem)
	case .Read:       it.num = g.read_rate
	case .Write:      it.num = g.write_rate
	case .Threads:    it.num = f64(g.threads)
	case:             sort_value(&it, sort, s, root)
	}
	return it
}

@(private = "file")
sort_value :: proc(it: ^Sort_Item, c: Column, s: ^Sampler, p: ^Proc) {
	switch c {
	case .Name:       it.text = p.name
	case .PID:        it.num = f64(p.pid)
	case .PPID:       it.num = f64(p.ppid)
	case .User:       it.text = p.user
	case .State:      it.text = state_text(p.state)
	case .Nice:       it.num = f64(p.nice)
	case .CPU:        it.num = f64(p.cpu)
	case .CPU_Graph:  it.num = f64(cpu_recent(p))
	case .Memory:     it.num = f64(p.private)
	case .Resident:   it.num = f64(p.resident)
	case .GPU:        it.num = f64(p.gpu)
	case .GPU_Memory: it.num = f64(p.gpu_mem)
	case .Read:       it.num = p.read_rate
	case .Write:      it.num = p.write_rate
	case .Threads:    it.num = f64(p.threads)
	case .Started:    it.num = f64(p.started)
	case .Command:    it.text = p.cmdline
	case .Executable: it.text = p.exe
	}
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

