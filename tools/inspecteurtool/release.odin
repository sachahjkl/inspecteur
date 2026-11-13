package inspecteurtool

// A release, the same steps on a laptop and in the release workflow: the toolkit's commands (gt:release).
//
//   package [version]       build/dist: inspecteur-<version>-linux-x64.tar.gz (the program, its licence and the
//                           third-party notices, the README and the changelog), its SHA-256, the program alone and, with
//                           $UPDATE_SIGNING_KEY, its signed update manifest; a version given must be APP_VERSION
//   notes <version>         the changelog's section of that version (the notes of its GitHub release)
//   ship <patch|minor|major|x.y.z> [--dry-run]
//                           from a clean checkout: the fragments of changelog.d/ assembled into the next version with
//                           today's date, APP_VERSION set, a commit, the tag, the push. The release workflow checks the
//                           tag (inspecteurtool check), builds the archive and publishes it; the site follows.

import release "gt:release"
import toolbox "gt:toolbox"
import inspecteur_update "../../src/update"

// What goes beside the program in the archive: the file, and its name there (THIRD-PARTY-NOTICES holds the licences of
// what the program embeds and links: inspecteurtool notices).
@(rodata)
DIST_FILES := [?][2]string{{"README.md", "README.md"}, {"LICENSE", "LICENSE"}, {"THIRD-PARTY-NOTICES", "THIRD-PARTY-NOTICES"}, {"CHANGELOG.md", "CHANGELOG.md"}}

// (no check of its own before the tag: the release workflow runs inspecteurtool check on the tag, then builds)
release_config :: proc(p: toolbox.Project) -> release.Release_Options {
	return {project = p, dist = "build/dist", files = DIST_FILES[:], update = inspecteur_update.PRODUCT}
}
