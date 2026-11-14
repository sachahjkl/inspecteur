# inspecteur

A system monitor for Linux (Wayland first), in Odin, on the `ext/gui_toolkit` submodule (collection `gt`).

Read first: [README.md](README.md), [src/md/README.md](src/md/README.md), [docs/architecture.md](docs/architecture.md),
[docs/development.md](docs/development.md).

## Build and test

Every step is a command of `tools/inspecteurtool` (`help` lists them):

    odin run tools/inspecteurtool -collection:gt=ext/gui_toolkit/src -out:build/inspecteurtool -keep-executable -- <command>

- `build [release]` builds `build/inspecteur` (`build.sh` / `build.bat` are shortcuts).
- `check`: `odin check -vet`, the unit tests, THIRD-PARTY-NOTICES up to date, a release build. `live`: the real program
  in a headless sway (310 checks).
- `shots` makes the pictures of the documentation from `inspecteur --demo` (no data of the machine in them); `bench`
  measures the cold start and the CPU use at rest. `desktop_files <prefix>`: the Nix package's entry and icons.
  `notices`: THIRD-PARTY-NOTICES.
- `nix develop` first (`flake.nix`). `nix build` builds the package.

## Rules

- What more than one program needs goes in gui_toolkit, generic, with its docs, test and changelog fragment; inspecteur
  then points to the toolkit's new tag.
- A preference is a `config.Def` in `src/settings.odin` with its line in `docs/configuration.md` (a test checks it).
- A change a user can see is a fragment of `changelog.d/` (`inspecteurtool changelog new`, its README), in the same
  commit; `CHANGELOG.md` is never edited by hand: `ship` assembles the fragments.
- Tests never touch the person's desktop: `live`, `shots` and `bench` run in a sway of their own. A test sends a signal
  only to a process it started itself, found by a mark in its command line and checked by its pid; it acts on a service,
  an autostart entry, an app's group or a desktop entry only when it made it itself (an app's group: a scope it made,
  checked to hold its own processes alone). A key that changes something is pressed only after a check that the
  selected row is the test's own (`select_child`, `select_unit`), and the test stops when that check fails.
- Every reader of the system is in a `*_linux.odin` file behind plain structs, with its demo's counterpart in
  `src/demo.odin`; the models and views have no Linux in them ([src/md/infrastructure/porting.md](src/md/infrastructure/porting.md)).
- An action is a command of `COMMANDS` (`src/commands.odin`): its key, menu line and tooltip come from there.
- A picture of the documentation shows the demo only: `live`'s pictures stay in `build/live`.
- Automation is a command of `tools/inspecteurtool`, never a shell, batch, PowerShell, Python or Node script.
- Comments and commit messages are in English. Comments say why.
- Commits: author and committer `sachahjkl <sacha@sacha.house>`, no attribution trailer, no session link.

## Roadmap

- `ROADMAP.md`, beside `CHANGELOG.md`, holds inspecteur's planned work: `# Roadmap`, then `## Now`, `## Next` and
  `## Later`, each a list. Each entry starts with a bold summary, then one or two sentences on what it gives the user. No
  dates, no front matter.
- When a work is done, remove its entry in the same commit as its changelog fragment.
- Work that touches several programs goes in the roadmap of gui_toolkit.
- `inspecteurtool check` checks its format with the changelog's.

## Intent

This project follows <https://srcmd.org>, with the Markdown in `src/md`. Read `src/md/README.md` first.

- Change the intent first, then derive the code and the tests. A change of design changes its intent file in the same
  commit.
- Keep there what the code does not show: the purpose, the decisions, the refused alternatives, the subtle points.
- `src/md/README.md` lists every other file of the folder in its `## File Index`.
- The user's documentation and the developer's how-to stay in `docs/`; `src/md` links to them.
