# NetEOC documentation

NetEOC means **Network Enhanced Operations Center**. This repository is in MVP
development. The runtime and authentication shell is under construction; it is
not an operational emergency response application.

Read these documents in order:

1. [Project context and decisions](project-context.md): user requirements and
   accepted clarification answers; start here when joining the project.
2. [MVP PRD](prd.md): scope, workflows, and acceptance criteria.
3. [Architecture](architecture.md): data model, authorization, and GIS
   contracts.
4. [Technology research](research.md): primary sources, tradeoffs, and versions.
5. [Development plan](development-plan.md): milestones and release gates.
6. [MVP implementation contract](mvp-implementation-contract.md): build order,
   boundary decisions, and verification matrix.
7. [Authentication setup](auth-setup.md): bindings, email template, rate limits,
   and integration tests for the runtime slice.
8. [Development guidelines](development.md): setup, checks, and contribution
   rules.
9. [Security](security.md): threat model, scanning, and reporting.
10. [Repository status](status.md): completed work, verification, and next
    steps.
11. [Tenant kernel](tenant-kernel.md): first organization and membership read
    boundary and its authorization test.

Keep substantive documentation here in Markdown. If PDFs become useful, put them
in `docs/pdfs/` and link them from the relevant Markdown page. Do not copy
vendor PDFs without checking redistribution rights. `AGENTS.md` and the root
README are entry points; the GitHub PR template is workflow metadata.
