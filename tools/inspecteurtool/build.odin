package inspecteurtool

// build, test, check: the program and its tests.

import "core:fmt"
import "core:os"
import toolbox "gt:toolbox"

// What a build on Linux needs: the toolkit's native text backend, and the Rust standard library that both it and
// wgpu-native carry linked once (the same code: the toolkit's own CI does the same).
LINUX_DEFINES :: "-define:FONT_BACKEND=native"
LINUX_LINK    :: "-extra-linker-flags:-Wl,--allow-multiple-definition"
PROGRAM       :: "build/inspecteur"

toolkit :: proc() -> string {
	if v := os.get_env("GT", context.temp_allocator); v != "" { return v }
	return "ext/gui_toolkit"
}

collection :: proc() -> string { return fmt.tprintf("-collection:gt=%s/src", toolkit()) }

// An odin command on the program: the toolkit's collection, -vet, the text backend.
odin_cmd :: proc(verb: string, extra: []string) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", verb, "src", collection(), "-vet", LINUX_DEFINES)
	if verb != "check" { append(&cmd, LINUX_LINK) }   // (check links nothing)
	append(&cmd, ..extra)
	return cmd[:]
}

// The toolkit's text library, built by its own tool (it skips what is up to date).
build_text :: proc() -> bool {
	_ = os.make_directory_all(fmt.tprintf("%s/build", toolkit()))   // (a fresh checkout has none: the linker writes tk there)
	return toolbox.run({"odin", "run", "tools/tk", "-out:build/tk", "--", "build_text"}, {dir = toolkit(), echo = true})
}

run_build :: proc(args: []string) -> int {
	release := len(args) > 0 && args[0] == "release"
	if !build_text() { return 1 }
	_ = os.make_directory("build")
	extra := []string{"-out:" + PROGRAM, release ? "-o:speed" : "-debug"}
	if !toolbox.run(odin_cmd("build", extra), {echo = true}) { return 1 }
	fmt.printfln("built %s%s", PROGRAM, release ? " (release)" : "")
	return 0
}

run_test :: proc(args: []string) -> int {
	if !build_text() { return 1 }
	_ = os.make_directory("build")
	return toolbox.run(odin_cmd("test", {"-out:build/test_inspecteur"}), {echo = true}) ? 0 : 1
}

run_check :: proc(args: []string) -> int {
	if !toolbox.run(odin_cmd("check", nil), {echo = true}) { return 1 }
	if !toolbox.run({"odin", "check", "tools/inspecteurtool", collection(), "-vet"}, {echo = true}) { return 1 }
	if run_test(nil) != 0 { return 1 }
	return run_build({"release"})
}
