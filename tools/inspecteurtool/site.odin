package inspecteurtool

// The site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release. The steps are the
// toolkit's (gt:site, its `site` command); this file says what this site is: its address, names and colours.
//   inspecteurtool site build <site> <out>      the changelog's pages and the classic ones from <site>, then what a page
//                                           says when it is shared; <out> is what is published
//   inspecteurtool site check [--site folder] [--shot file.png] [--browser program]
//                                           the pages in a real browser, served on this machine
// {{version}} in the home page is the last version: its download link names the file of that release. The shop's pages
// (shop) are written after the toolkit's build.

import "core:fmt"
import "core:os"
import "core:strings"
import tk_site "gt:site"
import toolbox "gt:toolbox"
import inspecteur_licence "../../src/licence"

// Where the site is published, what it is: the one place that says it.
SITE_META :: tk_site.Meta{
	url         = "https://inspecteur.froment.software/",
	name        = "inspecteur",
	repository  = REPOSITORY,
	tagline     = "A fast native task manager for Linux",
	changes     = CHANGELOG,
	card        = "img/main.png",
	logo        = "img/logo.png",
	logo_file   = "site/img/logo.png",
	theme       = "#0d1620",
	accent      = "#5be7c4",
	author      = "Sacha Froment",
	author_url  = "https://froment.software",
	publisher   = "Froment Software",
	ld_type     = "SoftwareApplication",
	root_domain = false,   // (github.io answers for /robots.txt and /favicon.ico, not the site)
}

SITE_LD := [?][2]string{
	{"applicationCategory", "UtilitiesApplication"},
	{"operatingSystem", "Linux"},
	{"license", "https://opensource.org/license/mit"},
}

// The site as the toolkit's command takes it (its slices live as long as the tool: SITE_LD is a global).
site_project :: proc() -> tk_site.Project_Site {
	m := SITE_META
	m.ld_fields = SITE_LD[:]
	return {meta = m, dir = "site", pages = {version_mark = "{{version}}"}}
}

// The shop: inspecteur's licence (src/licence), sold through Paddle by the toolkit's licence Worker. Its pages (pricing,
// thanks, terms, refunds, privacy, imprint) are the toolkit's templates, filled at each `site build`. What is empty is
// the maintainer's to give once the shop is set up (gui_toolkit docs/licence.md, "What the maintainer does at the end"):
// until the client token, the price id and the Worker are there, the button says "Coming soon".

shop :: proc() -> tk_site.Shop {
	return {
		name           = "inspecteur",
		icon           = "../img/logo.png",
		product_title  = "inspecteur licence",
		price          = "15&nbsp;&euro;",
		price_note     = "",
		environment    = "sandbox",
		client_token   = "",   // Paddle's client-side token: "" keeps the shop shut ("Coming soon")
		edition        = "supporter",
		price_id       = "",   // what `inspecteurtool paddle -apply` prints ("": not made yet)
		worker         = "",   // the licence Worker's address (gui_toolkit licence-worker/README.md)
		thanks         = "https://inspecteur.froment.software/thanks/",
		help           = REPOSITORY + "/issues",
		register       = "Open inspecteur's settings (Ctrl+,), the <strong>General</strong> page, <strong>Licence</strong>: paste the key, or choose the file.",
		extension      = inspecteur_licence.PRODUCT.file_extension,
		seller         = "Froment Software",
		seller_url     = "https://froment.software",
		code_licence   = "MIT",
		stylesheet     = "../style.css",
		home           = "../",
		updated        = "2026-11-13",
	}
}

// The site's own command: the toolkit's, then the shop's pages written into what `site build` made.
site_command :: proc() -> toolbox.Command {
	inner := tk_site.command(site_project())
	return {name = inner.name, usage = inner.usage, run_with = site_run, user = new_clone(inner)}
}

@(private = "file")
site_run :: proc(args: []string, user: rawptr) -> int {
	inner := (^toolbox.Command)(user)
	code := inner.run_with(args, inner.user)
	if code != toolbox.EXIT_DONE || len(args) != 3 || args[0] != "build" { return code }
	for page in tk_site.licence_pages(shop()) {
		path := fmt.tprintf("%s/%s", args[2], page.path)
		_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])   // (there already, or the write says it)
		if os.write_entire_file(path, transmute([]u8)page.text) != nil { fmt.eprintfln("inspecteurtool site: %s cannot be written", path); return toolbox.EXIT_FAILED }
	}
	return toolbox.EXIT_DONE
}
