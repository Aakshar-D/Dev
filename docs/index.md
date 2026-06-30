# LinkedAlliance Hub — As-Built Specification

> **What this is:** Complete technical documentation of the LinkedAlliance Hub platform as built. Covers product features, RBAC, data model, integrations, and the MCP/AI layer. Not a roadmap — reflects what exists today.
>
> **How to keep it current:** When a new feature ships, update the relevant file and add any new DB entities to `04-data-model.md`. When a new integration is wired, update `05-integrations.md`. When the RBAC model changes (new role, new permission key), update `01-access-and-rbac.md` and the seed SQL in `linkedalliance/docs/custom-rbac-migration.sql`.

---

## Contents

| File | Covers |
|------|--------|
| [00-overview.md](00-overview.md) | What the product is, tech stack, capability map |
| [01-access-and-rbac.md](01-access-and-rbac.md) | Auth flows, roles, permission keys, impersonation, demo mode |
| [02-feature-modules.md](02-feature-modules.md) | Every feature module — route, problem, workflow, key tables |
| [03-desks.md](03-desks.md) | Role-workspace subsystem and all 6 desks |
| [04-data-model.md](04-data-model.md) | Full entity catalog by domain, RLS patterns |
| [05-integrations.md](05-integrations.md) | HubSpot, Google, Microsoft/Outlook, Gemini, Fathom, Ninety.io, AI/LLM map |
| [06-mcp-and-ai.md](06-mcp-and-ai.md) | Hub-as-MCP-server, OAuth 2.1 AS, ~50 tools, admin management |

## Change log

| File | Covers |
|------|--------|
| [changes/2026-06-26-microsoft-email-integration.md](changes/2026-06-26-microsoft-email-integration.md) | Microsoft (Outlook) email connection + provider-aware BDR draft |
