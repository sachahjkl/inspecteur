# inspecteur

A system monitor for Linux (Wayland first), in Odin, on the `ext/gui_toolkit` submodule (collection `gt`).

Read first: [README.md](README.md), [docs/architecture.md](docs/architecture.md), [docs/development.md](docs/development.md).

## Build and test

Every step is a command of `tools/inspecteurtool` (`help` lists them):

    odin run tools/inspecteurtool -collection:gt=ext/gui_toolkit/src -out:build/inspecteurtool -keep-executable -- <command>

- `build [release]` builds `build/inspecteur` (`build.sh` / `build.bat` are shortcuts).
- `check`: `odin check -vet`, the unit tests, a release build. `live`: the real program in a headless sway (36 checks).
- `shots` makes the pictures of the README; `bench` measures the cold start and the CPU use at rest.
- `nix develop` first (`flake.nix`). `nix build` builds the package.

## Rules

- What more than one program needs goes in gui_toolkit, generic, with its docs, test and changelog fragment; inspecteur
  then points to the toolkit's new tag.
- A preference is a `config.Def` in `src/settings.odin` with its line in `docs/configuration.md` (a test checks it).
- What changed goes under `## [Unreleased]` in `CHANGELOG.md`.
- Tests never touch the person's desktop: `live`, `shots` and `bench` run in a sway of their own. A test sends a signal
  only to a process it started itself, found by a mark in its command line and checked by its pid.
- Automation is a command of `tools/inspecteurtool`, never a shell, batch, PowerShell, Python or Node script.
- Comments and commit messages are in English. Comments say why.
- Commits: author and committer `sachahjkl <sacha@sacha.house>`, no attribution trailer, no session link.
