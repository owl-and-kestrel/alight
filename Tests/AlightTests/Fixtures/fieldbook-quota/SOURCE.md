# Fieldbook quota pace vectors

`astra-pace-golden.json` is copied verbatim from Fieldbook's Nest main
(`ssh://git@5.161.252.182/srv/git/fieldbook.git`,
`fixtures/quota/astra-pace-golden.json`) at commit
`d914356d332b6078bf42c873c7488313000013ab`, the quota layer pinned in
`scripts/build-core.mjs`. Fieldbook generated it from Astra's own Python
(`ok.fieldbook.quota-pace-golden.v1`). `FieldbookQuotaTests` runs every pace
vector through `CoreScript`, so the bundled pace math is checked in
JavaScriptCore. Refresh this file whenever the Fieldbook pin moves.
