# Development

## Setup

```sh
git clone --recurse-submodules <this repository>
cd inspecteur
nix develop        # the pinned Odin with wgpu-native, Rust, sway for live, shots and bench, the git hooks
```

Without Nix: Odin `dev-2026-11a` (`odin.version`), clang and lld, cargo (the toolkit's text library), wgpu-native's static
library in Odin's `vendor/wgpu/lib` (`odin run ext/gui_toolkit/tools/tk -- fetch_wgpu`), fontconfig; sway for the tests
that run the window.

## inspecteurtool

Every step is a command of `tools/inspecteurtool`. `./build.sh` is its shortcut for `build`.

```sh
odin run tools/inspecteurtool -collection:gt=ext/gui_toolkit/src -out:build/inspecteurtool -keep-executable -- help
```

| Command | What it does |
|---|---|
| `build [release]` | the toolkit's text library (when its sources changed), then `build/inspecteur` |
| `test` | the unit tests of `src` |
| `check` | `odin check -vet` of the program and the tool, the tests, a release build |
| `live [--keep]` | the real program in a headless sway, driven over the DevTools protocol; writes `docs/screenshots/processes.png` |
| `shots [--out folder]` | the pictures of the README, the program's own frames |
| `bench [seconds]` | a release build in a headless sway that draws on the GPU: the time to the first frame, the CPU use at rest |

`GT=<folder>` builds against another checkout of gui_toolkit.

The headless sway of `live` and `shots` draws on the CPU (pixman): inspecteur then draws with Mesa's software Vulkan.
`bench` uses sway's Vulkan renderer, so that inspecteur draws on the GPU as on a desktop.

## Measures

`inspecteur --first-frame` prints when its first frame was drawn and where the time went (reading `/proc`, opening the
window, the first frame), and at the end what a sample and a frame cost. `bench` reads it. On the author's machine (16
cores, NVIDIA 595, about 200 processes):

| | |
|---|---|
| cold start (process start to the end of the first frame) | 265 to 280 ms: `/proc` 12 ms, the window 230 ms, the first frame 20 ms |
| at rest, the table read each second | 1.0 % of one core, 160 MB resident (most of it the GPU driver) |
| a sample | 6 to 7 ms (`stat` about 5 ms, `io` about 1.5 ms) |
| a frame | 1.3 ms |

## Drive the window

An inspecteur started with `TOOLKIT_DEVTOOLS=<port>` serves the Chrome DevTools Protocol: the toolkit's `tk cdp` reads its
box tree, clicks, types and takes pictures.

```sh
TOOLKIT_DEVTOOLS=9222 build/inspecteur
odin run ext/gui_toolkit/tools/tk -- cdp --port 9222 tree , shot window.png
```

## A change

- Comments and commit messages are in English. Comments say why.
- A setting is a `config.Def` in `src/settings.odin`, with its line in [configuration.md](configuration.md) (a test checks
  it).
- What another program could use goes in gui_toolkit, generic, with its documentation, its test and its changelog
  fragment; inspecteur then points to the toolkit's new tag.
- Add what changed under `## [Unreleased]` in `CHANGELOG.md`.
