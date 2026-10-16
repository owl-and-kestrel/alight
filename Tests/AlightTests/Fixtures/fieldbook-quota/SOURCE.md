# Fieldbook quota pace vectors

`astra-pace-golden.json` is copied verbatim from Fieldbook
(`/Users/jon/Projects/fieldbook`, `fixtures/quota/astra-pace-golden.json`) at
commit `70a13675a443ee80183ef0dca125661791345ce7`, the quota layer pinned in
`scripts/build-core.mjs`. Fieldbook generated it from Astra's own Python
(`ok.fieldbook.quota-pace-golden.v1`). `FieldbookQuotaTests` runs every pace
vector through `CoreScript`, so the bundled pace math is checked in
JavaScriptCore. Refresh this file whenever the Fieldbook pin moves.
