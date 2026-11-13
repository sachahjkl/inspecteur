// What inspecteur's licence is to the toolkit's licence package (gt:licence, docs/licence.md): its name in the payload,
// its key's tag, what its signatures cover, its file and its editions. The program checks with it (src/licence.odin),
// inspecteurtool signs and checks with it (`inspecteurtool licence`), and the licence Worker is set from the same values
// (its products/inspecteur.jsonc).
package inspecteur_licence

import licence "gt:licence"

PRODUCT :: licence.Product{
	name           = "inspecteur",
	title          = "Inspecteur",
	version_tag    = "INSPECTEUR1",
	sign_context   = "inspecteur-licence-v1\n",
	file_extension = ".inspecteurlicence",
	// (`inspecteurtool licence keygen` makes the pair; empty until then: no licence of the real key is accepted)
	public_key     = "",
	// (the development pair: its seed is public on purpose, inspecteurtool's DEV_SEED; only a debug build accepts it)
	dev_public_key = "AdStxVdn8FsJ4eil4es_IaBkqV0p0Vn1jV7sCbozGyA",
	editions       = {0 = {id = "supporter", title = "Supporter"}, 1 = {id = "patron", title = "Patron"}},
}
