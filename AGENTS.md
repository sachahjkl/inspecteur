# inspecteur

A system monitor for Linux (Wayland first), in Odin, on the `ext/gui_toolkit` submodule (collection `gt`).

Read first: [README.md](README.md), [docs/architecture.md](docs/architecture.md), [docs/development.md](docs/development.md).

## Build and test

Every step is a command of `tools/inspecteurtool` (`help` lists them):

    odin run tools/inspecteurtool -collection:gt=ext/gui_toolkit/src -out:build/inspecteurtool -keep-executable -- <command>

- `build [release]` builds `build/inspecteur` (`build.sh` / `build.bat` are shortcuts).
- `check`: `odin check -vet`, the unit tests, a release build. `live`: the real program in a headless sway (245 checks).
- `shots` makes the pictures of the documentation from `inspecteur --demo` (no data of the machine in them); `bench`
  measures the cold start and the CPU use at rest. `desktop_files <prefix>`: the Nix package's entry and icons.
- `nix develop` first (`flake.nix`). `nix build` builds the package.

## Rules

- What more than one program needs goes in gui_toolkit, generic, with its docs, test and changelog fragment; inspecteur
  then points to the toolkit's new tag.
- A preference is a `config.Def` in `src/settings.odin` with its line in `docs/configuration.md` (a test checks it).
- What changed goes under `## [Unreleased]` in `CHANGELOG.md`.
- Tests never touch the person's desktop: `live`, `shots` and `bench` run in a sway of their own. A test sends a signal
  only to a process it started itself, found by a mark in its command line and checked by its pid; it acts on a service,
  an autostart entry, an app's group or a desktop entry only when it made it itself (an app's group: a scope it made,
  checked to hold its own processes alone). A key that changes something is pressed only after a check that the
  selected row is the test's own (`select_child`, `select_unit`), and the test stops when that check fails.
- Every reader of the system is in a `*_linux.odin` file behind plain structs, with its demo's counterpart in
  `src/demo.odin`; the models and views have no Linux in them (`docs/architecture.md`, "Porting to Windows").
- An action is a command of `COMMANDS` (`src/commands.odin`): its key, menu line and tooltip come from there.
- A picture of the documentation shows the demo only: `live`'s pictures stay in `build/live`.
- Automation is a command of `tools/inspecteurtool`, never a shell, batch, PowerShell, Python or Node script.
- Comments and commit messages are in English. Comments say why.
- Commits: author and committer `sachahjkl <sacha@sacha.house>`, no attribution trailer, no session link.
