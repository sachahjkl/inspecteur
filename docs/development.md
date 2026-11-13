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
| `check` | `odin check -vet` of the program and of the tool, the ui scopes (`toolbox.check_scopes`), the tests, the changelog's fragments, THIRD-PARTY-NOTICES up to date, a release build |
| `live [--keep]` | the real program in a headless sway, driven over the DevTools protocol (310 checks); its pictures stay in `build/live` |
| `shots [--out folder]` | the pictures of the documentation, the program's own frames, of the demo's made-up machine |
| `bench [seconds]` | a release build in a headless sway that draws on the GPU: the time to the first frame, the CPU use at rest, then with Services and with Connections shown |
| `logo` | `assets/logo*.png` and `.project/image.png`, drawn by the toolkit's paint package |
| `desktop_files <prefix>` | the desktop entry and the icons under `<prefix>/share`: what the Nix package installs |
| `notices [--check]` | THIRD-PARTY-NOTICES (the toolkit's `notices_command`): the licences of what the program embeds and links (gui_toolkit and its attributions, Roboto, Inconsolata, Lucide, Odin's core library, wgpu-native, the text library's crates from `cargo metadata`); `--check` fails when it is not up to date |
| `site build <site> <out>`, `check`, `card` | the site's pages (gui_toolkit's `gt:site`), then the shop's: pricing, thanks, terms, refunds, privacy, imprint (`shop` in `tools/inspecteurtool/site.odin`; "Coming soon" until the shop is set up) |
| `update keygen \| pubkey \| manifest \| verify` | inspecteur's update key and its signed manifests |
| `licence keygen \| pubkey \| issue \| verify \| secrets`, `paddle [-apply]` | the licence's key pair, a licence issued by hand, a check, the licence Worker's secrets; the Paddle catalogue (gui_toolkit's `toolbox.licence_commands`, its docs/licence.md). `-dev` uses the development pair (`DEV_SEED`, public on purpose) |
| `package [version]`, `notes <version>`, `ship <patch\|minor\|major\|x.y.z>` | the release's archive (the program, LICENSE, THIRD-PARTY-NOTICES, README, CHANGELOG) and its SHA-256; the changelog's section; the release itself from a clean `master`, the fragments assembled (gui_toolkit's `gt:release` and `gt:changelog`) |
| `changelog new <type> <subject> <text>`, `check`, `preview` | a fragment of `changelog.d/`; all of them well formed (`check` runs it); what the next version brings |

`GT=<folder>` builds against another checkout of gui_toolkit.

The commands are given to the toolkit's dispatcher (`toolbox.tool_main`); `changelog`, `site`, `logo`, `notices`,
`package`, `notes` and `ship` are the toolkit's own commands over the project (`toolbox.Project`, `tools/inspecteurtool/build.odin`).
`live`, `shots` and `bench` run in the toolkit's headless sway (`toolbox.sway_start`).

The headless sway of `live` and `shots` draws on the CPU (pixman): inspecteur then draws with Mesa's software Vulkan.
`bench` uses sway's Vulkan renderer, so that inspecteur draws on the GPU as on a desktop.

The session has a runtime folder, a configuration folder and a data folder of its own (`live`: a cache too, for a dump
file; the others keep the person's, as fontconfig's cache costs most of a second to build again), and no
`XDG_CURRENT_DESKTOP`; the install's dialog is not offered unless a test asks for it. `live` gives inspecteur the person's session bus (`DBUS_SESSION_BUS_ADDRESS`, else the
user manager's `$XDG_RUNTIME_DIR/bus`), so that the Services and Startup sections reach the user's service manager. It
acts only on what it made itself, and checks it before it presses a key that acts:

- processes it started (`sleep` with a mark of its own in its command line, found by the mark and checked by its pid; a
  shell and two sleeps for End process tree): the rows marked, a tree's processes, the affinity and the dump act only
  once the confirmation, or the row selected, names those processes and no other;
- a transient service (`systemd-run --user --unit=inspecteur-live-<pid>`), stopped and reset at the end;
- an app of its own: a desktop entry in the session's data folder, and two sleeps in a scope named for it
  (`systemd-run --user --scope --unit=app-inspecteurlive<pid>-1.scope`); the group is killed only once the scope holds
  those two and nothing else;
- an autostart entry, and the install of the install's dialog and of `inspecteur install` (the program, its desktop entry
  and icons), all in the session's folders.

Without a session bus (neither address), `live` says so and skips the checks of the user's service and of the app's
group. It never opens a web page, a file manager or a text editor: Search online, Open file location and Open unit file
would act on the person's desktop.

## The pictures, without the machine's data

`shots` runs `inspecteur --demo`: every reading (processes, CPU, memory, disks, interfaces, GPUs, services, startup
items, sockets, the system's details, a process's properties) comes from `src/demo.odin`, made up, in place of the
system's, and the demo acts on nothing. So the pictures show no host or user name, no home folder, no address or MAC
(the demo's are of the ranges kept for documentation: 192.0.2.0/24, 2001:db8::/32, 00:00:5e:00:53:xx), no service or app
of the machine. The demo fills its graphs' last minute before its first frame. Nothing else of the session is used:
no session bus. `live`'s own pictures (of the real machine) stay in `build/live`, which is not committed.

## Measures

`inspecteur --first-frame` prints when its first frame was drawn and where the time went (reading `/proc`, opening the
window, the first frame), and at the end what a sample and a frame cost. `bench` reads it. On the author's machine (16
cores, NVIDIA 595, about 200 processes):

| | |
|---|---|
| cold start (process start to the end of the first frame) | about 270 ms (261 to 279, median 270): `/proc` 14 ms, the window 215 to 230 ms, the first frame 30 ms |
| at rest, the table read each second | 1.0 to 1.1 % of one core, 187 MB resident (most of it the GPU driver) |
| Services shown (read every 3 s, the selected one's details and journal with them) | 1.6 % of one core |
| Connections shown (read each second) | 2.0 % of one core |
| a sample | 7.2 ms (`stat`, `statm` and `io` of about 200 processes) |
| a frame | 7.7 ms on the mean of a bench's frames (most of them with Services or Connections shown); at rest, a frame a second |

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
- An action is a command of `COMMANDS` (`src/commands.odin`): its key, its menu line and its tooltip come from there, and
  the palette and the sheet of the keys list it. A test checks that no key does two things in one place.
- A reading of the system goes in a `*_linux.odin` file, behind the plain structs of its model, and gets its demo's
  counterpart in `src/demo.odin` (see [architecture.md](architecture.md), "Porting to Windows").
- What another program could use goes in gui_toolkit, generic, with its documentation, its test and its changelog
  fragment; inspecteur then points to the toolkit's new tag.
- Write what a user sees changed as a fragment of `changelog.d/` (`inspecteurtool changelog new <type> <subject> <text>`;
  `changelog.d/README.md`). Never edit `CHANGELOG.md`: `ship` assembles the fragments into the version's section.
