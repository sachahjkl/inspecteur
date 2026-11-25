package inspecteurtool

// bench_reader: opt-in benchmark of the Linux /proc, machine, sockets and GPU readers and the neutral pipeline,
// including a 5,000-process synthetic /proc tree verified against the plain reference reader.
//
//   inspecteurtool bench_reader [--fast]

import "core:fmt"
import "core:os"
import cli "gt:cli"
import toolbox "gt:toolbox"

run_bench_reader :: proc(args: []string) -> cli.Exit {
	fast := false
	for a in args {
		if a == "--fast" { fast = true }
	}
	p := project()
	if !toolbox.build_native(p, release = !fast) { return .Failed }
	_ = os.make_directory_all(toolbox.BUILD_DIR)
	extra := []string{
		fmt.tprintf("-out:%s/bench_reader", toolbox.BUILD_DIR),
		"-define:ODIN_TEST_THREADS=1",
		"-define:ODIN_TEST_NAMES=inspecteur.bench_readers_and_neutral,inspecteur.bench_synthetic_5000",
		fast ? "-o:none" : "-o:speed",
	}
	cmd := toolbox.odin_command(p, "test", "", extra, release = !fast)
	ok := toolbox.run(cmd, {env = toolbox.env_with(nil, "INSPECTEUR_BENCH=1"), echo = true})
	return ok ? .Done : .Failed
}
