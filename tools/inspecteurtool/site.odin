package inspecteurtool

// The site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release. The steps are the
// toolkit's (gt:site, its `site` command); this file says what this site is: its address, names and colours.
//   inspecteurtool site build <site> <out>      the changelog's pages and the classic ones from <site>, then what a page
//                                           says when it is shared; <out> is what is published
//   inspecteurtool site check [--site folder] [--shot file.png] [--browser program]
//                                           the pages in a real browser, served on this machine
// {{version}} in the home page is the last version: its download link names the file of that release. The shop's pages
// (shop) are made with the others (Meta.shop).

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
	publisher_logo = "img/froment-software-64.png",
	licence     = "MIT",
}

// The home page's download: the one system the release builds for.
@(rodata)
SITE_DOWNLOADS := [?]tk_site.Download{
	{os = "linux", label = "Linux", href = "https://github.com/sachahjkl/inspecteur/releases/download/v{{version}}/inspecteur-{{version}}-linux-x64.tar.gz", detail = "v{{version}} · x64 · .tar.gz · Wayland"},
}

SITE_LD := [?][2]string{
	{"applicationCategory", "UtilitiesApplication"},
	{"operatingSystem", "Linux"},
	{"license", "https://opensource.org/license/mit"},
}

// The site as the toolkit's command takes it (its slices live as long as the tool: SITE_LD and SITE_DOWNLOADS are globals).
site_project :: proc() -> tk_site.Project_Site {
	m := SITE_META
	m.ld_fields = SITE_LD[:]
	m.shop = shop()
	return {meta = m, dir = "site", pages = {version_mark = "{{version}}", downloads = SITE_DOWNLOADS[:]}}
}

// The shop: inspecteur's licence (src/licence), sold through Paddle by the toolkit's licence Worker. Its pages (pricing,
// thanks, terms, refunds, privacy, imprint) are the toolkit's templates, filled at each `site build` (Meta.shop). What is empty is
// the maintainer's to give once the shop is set up (gui_toolkit docs/licence.md, "What the maintainer does at the end"):
// until the client token, the price id and the Worker are there, the button says "Coming soon".

shop :: proc() -> tk_site.Shop {
	return {
		name           = "inspecteur",
		icon           = "../img/logo.png",
		product_title  = "Inspecteur User License",
		price          = "15&nbsp;&euro;",
		price_note     = "",
		environment    = "sandbox",
		client_token   = "",   // Paddle's client-side token: "" keeps the shop shut ("Coming soon")
		edition        = "supporter",
		price_id       = "",   // what `inspecteurtool paddle -apply` prints ("": not made yet)
		worker         = "",   // the licence Worker's address (gui_toolkit licence-worker/README.md)
		thanks         = "https://inspecteur.froment.software/thanks/",
		help           = REPOSITORY + "/issues/new",
		register       = "Open inspecteur's settings (Ctrl+,), the <strong>General</strong> page, <strong>Licence</strong>: paste the key, or choose the file.",
		extension      = inspecteur_licence.PRODUCT.file_extension,
		repository     = REPOSITORY,
		seller         = SELLER,
		code_licence   = "MIT License",
		platform       = "Linux, x64 (Wayland).",
		network        = "inspecteur connects to the network for its updates only: the installed copy asks GitHub for the latest release a while after it starts and then once a day, and puts an update in place only if it is signed by Froment Software. Another copy asks only when you press <em>Check now</em> in the settings.",
		stylesheet     = "../style.css",
		home           = "../",
		updated        = "2026-11-13",
	}
}

// The seller, as Wren's imprint names it: the same block in every program of Froment Software.
SELLER :: tk_site.Seller{
	name       = "Froment Software",
	owner      = "Sacha Froment",
	status     = "sole proprietor (<em>entrepreneur individuel</em>)",
	address    = "7 Lieu-dit les Renardi&egrave;res, 72220 Marign&eacute;-Laill&eacute;, France",
	email      = "contact@froment.software",
	url        = "https://froment.software",
	siren      = "131 941 718",
	siret      = "131 941 718 00010",
	ape        = "6201Z, computer programming",
	registry   = "the French national register of companies (RNE)",
	registered = "23 October 2026",
	vat        = "not applicable, article 293 B of the French General Tax Code (<em>franchise en base de TVA</em>)",
}

// The site's command: the toolkit's, the shop's pages among the others (Meta.shop).
site_command :: proc() -> toolbox.Command {
	return tk_site.command(site_project())
}
