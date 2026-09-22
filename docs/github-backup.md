# GitHub backup

Nest is Alight's source authority. GitHub is a downstream backup and
collaboration projection; direct GitHub writes may block automatic mirroring
and must be reconciled rather than force-overwritten.

The first selected-repository GitHub App canary was activated on 2026-07-30:

- App: `Nest Backup Mirror` (`4434471`)
- installation: `150057298`
- GitHub repository: `owl-and-kestrel/alight` (historical canary: `owl-and-kestrel/glideslope` `1241438475`)
- transport: short-lived, repository-scoped installation token
- permissions: Contents read/write and Metadata read-only

The Nest mirror worker verifies the installation's current selected-repository
grant before each non-force push and confirms that GitHub's branch SHA exactly
matches the Nest-owned branch afterward. App private keys, JWTs, and
installation tokens remain server-only.
