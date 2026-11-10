package inspecteurtool

// notices: THIRD-PARTY-NOTICES, the licences of what the executable holds besides inspecteur's own code, as a binary's
// distribution must give them:
//
//   - gui_toolkit (MIT) and its attributions (NOTICE.md: the RAD Debugger's design, Slug's shader);
//   - the fonts it embeds: Roboto (Apache-2.0) and Inconsolata (SIL OFL 1.1), the fallbacks of src/font/font.odin;
//     Lucide's icons (ISC);
//   - wgpu-native (MIT or Apache-2.0), linked statically (its licence texts are kept in tools/inspecteurtool/licences:
//     its release archive has none);
//   - the Rust crates of the toolkit's text library, linked statically: those the library's build links (not its build
//     scripts' crates), from `cargo metadata` of native/text, each crate's own licence files.
//
//   inspecteurtool notices           writes THIRD-PARTY-NOTICES
//   inspecteurtool notices --check   fails when THIRD-PARTY-NOTICES is not what it would write (check runs it)

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import toolbox "gt:toolbox"

NOTICES_FILE :: "THIRD-PARTY-NOTICES"
// The target the crates are linked for: the release's.
NOTICES_TARGET :: "x86_64-unknown-linux-gnu"

@(private = "file")
WGPU_MIT :: #load("licences/wgpu-native-LICENSE.MIT", string)
@(private = "file")
WGPU_APACHE :: #load("licences/wgpu-native-LICENSE.APACHE", string)

run_notices :: proc(args: []string) -> int {
	check_only := len(args) > 0 && args[0] == "--check"
	text, why := notices_text()
	if why != "" { fmt.eprintfln("inspecteurtool notices: %s", why); return 1 }
	if check_only {
		old, err := os.read_entire_file(NOTICES_FILE, context.temp_allocator)
		if err != nil || string(old) != text {
			fmt.eprintfln("inspecteurtool notices: %s is not up to date (inspecteurtool notices writes it)", NOTICES_FILE)
			return 1
		}
		fmt.printfln("%s is up to date", NOTICES_FILE)
		return 0
	}
	if os.write_entire_file(NOTICES_FILE, text) != nil { fmt.eprintfln("inspecteurtool notices: %s cannot be written", NOTICES_FILE); return 1 }
	fmt.printfln("wrote %s", NOTICES_FILE)
	return 0
}

// A work and its licence texts.
@(private = "file")
Work :: struct { name, licence: string, texts: []string }

@(private = "file")
notices_text :: proc() -> (text: string, why: string) {
	gt := toolkit()
	read :: proc(path: string) -> (string, bool) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		return string(data), err == nil
	}
	files := [?]struct { name, licence, path: string }{
		{"gui_toolkit", "MIT", "LICENSE"},
		{"gui_toolkit's attributions (the RAD Debugger's design, MIT; Slug's shader, MIT)", "MIT", "NOTICE.md"},
		{"Roboto (the embedded interface font)", "Apache-2.0", "src/font/data/Roboto-LICENSE.txt"},
		{"Inconsolata (the embedded monospace font)", "OFL-1.1", "src/font/data/Inconsolata-OFL.txt"},
		{"Lucide (the icons)", "ISC", "src/lucide/LICENSE.txt"},
	}
	works := make([dynamic]Work, context.temp_allocator)
	for f in files {
		t, ok := read(fmt.tprintf("%s/%s", gt, f.path))
		if !ok { return "", fmt.tprintf("%s/%s cannot be read", gt, f.path) }
		append(&works, Work{f.name, f.licence, slice.clone([]string{t}, context.temp_allocator)})
	}
	append(&works, Work{"wgpu-native (wgpu, naga)", "MIT OR Apache-2.0", slice.clone([]string{WGPU_MIT, WGPU_APACHE}, context.temp_allocator)})
	crates, cwhy := linked_crates(fmt.tprintf("%s/native/text", gt))
	if cwhy != "" { return "", cwhy }

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "Third-party notices\n\n")
	strings.write_string(&b, "Inspecteur is under the MIT licence (LICENSE). Its executable also holds the works below, each under its own\n")
	strings.write_string(&b, "licence, whose text follows. This file is written by `inspecteurtool notices`.\n\n")
	for w in works { fmt.sbprintf(&b, "- %s: %s\n", w.name, w.licence) }
	strings.write_string(&b, "- the Rust crates of gui_toolkit's text library (native/text):\n")
	for c in crates { fmt.sbprintf(&b, "  - %s %s: %s\n", c.name, c.version, c.licence) }
	for w in works {
		fmt.sbprintf(&b, "\n%s\n%s (%s)\n%s\n\n", RULE, w.name, w.licence, RULE)
		for t, i in w.texts {
			if i > 0 { strings.write_string(&b, "\n----\n\n") }
			strings.write_string(&b, strings.trim_space(t))
			strings.write_byte(&b, '\n')
		}
	}
	// the crates' texts, each text once with the crates that ship it
	Group :: struct { text: string, names: [dynamic]string }
	groups := make([dynamic]Group, context.temp_allocator)
	at := make(map[string]int, 64, context.temp_allocator)
	for c in crates {
		for t in c.texts {
			key := digest(t)
			k, seen := at[key]
			if !seen {
				k = len(groups)
				at[key] = k
				append(&groups, Group{text = t, names = make([dynamic]string, context.temp_allocator)})
			}
			name := fmt.tprintf("%s %s", c.name, c.version)
			if !slice.contains(groups[k].names[:], name) { append(&groups[k].names, name) }
		}
	}
	for g in groups {
		fmt.sbprintf(&b, "\n%s\n%s\n%s\n\n%s\n", RULE, strings.join(g.names[:], ", ", context.temp_allocator), RULE, strings.trim_space(g.text))
	}
	return strings.to_string(b), ""
}

@(private = "file")
RULE :: "================================================================================"

@(private = "file")
digest :: proc(text: string) -> string {
	sum := hash.hash_string(.SHA256, strings.trim_space(text), context.temp_allocator)
	return string(hex.encode(sum, context.temp_allocator))
}

@(private = "file")
Crate :: struct { name, version, licence: string, texts: []string }

// The crates the library at `dir` links for NOTICES_TARGET: from its own package, the dependencies of the normal kind
// (not a build script's, not a test's, not a procedural macro), crate after crate; each with its licence files (LICENSE*, LICENCE*, COPYING*,
// NOTICE*, and the file its manifest names), sorted by name.
@(private = "file")
linked_crates :: proc(dir: string) -> (out: []Crate, why: string) {
	meta, code := toolbox.capture({"cargo", "metadata", "--format-version", "1", "--locked", "--offline", "--filter-platform", NOTICES_TARGET, "--manifest-path", fmt.tprintf("%s/Cargo.toml", dir)})
	if code != 0 { return nil, "cargo metadata failed (the text library's crates are fetched by `inspecteurtool build`)" }
	root, err := json.parse_string(meta, allocator = context.temp_allocator)
	if err != nil { return nil, "cargo metadata's output cannot be read" }
	top := root.(json.Object) or_else nil
	packages := top["packages"].(json.Array) or_else nil
	resolve := top["resolve"].(json.Object) or_else nil
	by_id := make(map[string]json.Object, 128, context.temp_allocator)
	for p in packages {
		o := p.(json.Object) or_else nil
		by_id[str(o["id"])] = o
	}
	nodes := make(map[string]json.Object, 128, context.temp_allocator)
	for n in resolve["nodes"].(json.Array) or_else nil {
		o := n.(json.Object) or_else nil
		nodes[str(o["id"])] = o
	}
	// the crates linked: from the root, the dependencies of the normal kind
	linked := make(map[string]bool, 128, context.temp_allocator)
	todo := make([dynamic]string, context.temp_allocator)
	append(&todo, str(resolve["root"]))
	for len(todo) > 0 {
		id := pop(&todo)
		for d in nodes[id]["deps"].(json.Array) or_else nil {
			dep := d.(json.Object) or_else nil
			normal := false
			for k in dep["dep_kinds"].(json.Array) or_else nil {
				if kind, is_obj := k.(json.Object); is_obj { if _, is_null := kind["kind"].(json.Null); is_null { normal = true } }
			}
			pkg := str(dep["pkg"])
			// (a procedural macro runs in the compiler: none of it is linked)
			if !normal || linked[pkg] || proc_macro(by_id[pkg]) { continue }
			linked[pkg] = true
			append(&todo, pkg)
		}
	}
	list := make([dynamic]Crate, context.temp_allocator)
	for id in linked {
		p := by_id[id]
		folder := filepath.dir(str(p["manifest_path"]))
		texts := make([dynamic]string, context.temp_allocator)
		names := make([dynamic]string, context.temp_allocator)
		if fis, ferr := os.read_all_directory_by_path(folder, context.temp_allocator); ferr == nil {
			for fi in fis {
				up := strings.to_upper(fi.name, context.temp_allocator)
				for prefix in ([]string{"LICENSE", "LICENCE", "COPYING", "NOTICE"}) {
					if strings.has_prefix(up, prefix) { append(&names, fi.name); break }
				}
			}
		}
		if lf := str(p["license_file"]); lf != "" && !slice.contains(names[:], lf) { append(&names, lf) }
		slice.sort(names[:])
		for n in names {
			if data, rerr := os.read_entire_file(fmt.tprintf("%s/%s", folder, n), context.temp_allocator); rerr == nil { append(&texts, string(data)) }
		}
		licence := str(p["license"])
		if len(texts) == 0 { return nil, fmt.tprintf("the crate %s %s ships no licence file", str(p["name"]), str(p["version"])) }
		append(&list, Crate{str(p["name"]), str(p["version"]), licence != "" ? licence : "see its licence file", texts[:]})
	}
	slice.sort_by(list[:], proc(a, b: Crate) -> bool { return a.name != b.name ? a.name < b.name : a.version < b.version })
	return list[:], ""
}

@(private = "file")
proc_macro :: proc(p: json.Object) -> bool {
	for t in p["targets"].(json.Array) or_else nil {
		for k in (t.(json.Object) or_else nil)["kind"].(json.Array) or_else nil { if str(k) == "proc-macro" { return true } }
	}
	return false
}

@(private = "file")
str :: proc(v: json.Value) -> string { return v.(json.String) or_else "" }
