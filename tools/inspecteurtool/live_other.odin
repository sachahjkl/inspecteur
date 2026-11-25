#+build !linux
package inspecteurtool

// Non-Linux stubs for the headless sway commands (live, shots, bench).

import "core:fmt"
import cli "gt:cli"

run_live :: proc(_: []string) -> cli.Exit {
	fmt.eprintln("inspecteurtool live: headless sway sessions run on Linux only; run `inspecteurtool check` here")
	return .Failed
}

run_shots :: proc(_: []string) -> cli.Exit {
	fmt.eprintln("inspecteurtool shots: headless sway screenshot capture runs on Linux only")
	return .Failed
}

run_bench :: proc(_: []string) -> cli.Exit {
	fmt.eprintln("inspecteurtool bench: headless sway benchmarks run on Linux only")
	return .Failed
}
