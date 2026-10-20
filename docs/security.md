# Security baseline

Report suspected vulnerabilities privately through GitHub's security advisory
flow or the repository maintainers; never include credentials in a public issue.
If a secret is exposed, revoke/rotate it immediately and investigate history,
build logs, and downstream access. A Git revert does not remove the exposure.

The [MVP threat model](threat-model.md) maps assets, trust boundaries, abuse
paths, and release tests. Its highest-priority risks include cross-organization
access, visibility confusion, privileged RLS bypass, malicious third-party GIS
URLs, photo or credential leakage, and unavailable or stale data during response
operations. See the [architecture](architecture.md) for the access contract and
[PRD](prd.md) for acceptance evidence.

The repository uses three complementary scanners: TruffleHog for credentials,
Trivy for vulnerable dependencies, configuration, and secrets, and Semgrep for
source patterns. Local hooks run the staged secret scan; CI repeats checks on
complete PR commits. Checks are fail-closed, and all scan tooling is versioned.
The GitHub workflow uses read-only permissions for PR jobs and no production
secrets. GitHub branch protection and native secret scanning are enabled in
repository settings as an additional merge boundary. Setup status is tracked in
[status](status.md).

Security review is required before production for database grants/RLS, Storage
policies, server-side GIS token verification, external feed fetching, export
cache headers, upload validation, backup/restore, and provider/privacy terms.
Log access changes and token use without saving token values. Establish incident
contacts, retention, recovery targets, and change ownership before a real
incident pilot.
