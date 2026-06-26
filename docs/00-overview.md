# 00 — Overview

## What it is

The **LinkedAlliance Hub** is a multi-tenant SaaS operating system for the **Linked Accounting Alliance (LAA)** — a network of independent CPA and accounting firms. It serves as the alliance's shared platform for CRM, project and task management, performance reviews, service delivery, knowledge management, compliance, and AI-assisted workflows.

All data is scoped to a single alliance tenant. Member firms share the platform but are segmented by org, role, and permission.

## Tech stack

| Layer | Technology |
|-------|-----------|
| Frontend | React 18, React Router v6, TypeScript |
| Build | Vite 5 + SWC, bundled as a single-page app |
| UI | shadcn/ui (Radix UI) + Tailwind CSS 3.4 |
| Server state | TanStack React Query v5 |
| Backend | Supabase (Postgres + PostgREST + Auth + Storage + Edge Functions) |
| Rich text | TipTap |
| Charts | Recharts, D3-geo, Leaflet |
| Package manager | npm (bun.lock also present) |
| Deployment | Vercel (SPA, `vercel.json` present) |

Path alias: `@/` → `src/`.

## Capability map

| Domain | What it covers |
|--------|---------------|
| **CRM & Directory** | People (Members), firms (Companies), org hierarchy (OrgChart), external suppliers (Vendors) |
| **Work Management** | Projects, tasks, kanban boards, task automations, recurring tasks, saved views, shared-project tokens |
| **Performance / Talent** | Recurring check-ins, 9-box talent grid |
| **Help Desk / SSG** | Ticketing system, Shared Services Group marketplace |
| **Knowledge & Content** | Internal wiki (KB), announcements, document library |
| **Software Spend** | SaaS comparison matrix, firm stacks, spend dashboard |
| **Referral Compliance** | Profession-based rules engine, agreement generation, payout tracking |
| **RFP Marketplace** | Post and respond to RFPs across the alliance |
| **Wealth Management** | AUM, opportunity, contacts/accounts reporting; CRM sync |
| **Reporting & Analytics** | HubSpot-sourced sales pipeline and performance dashboards |
| **Role Desks** | Bespoke daily workspaces per role (BDR, SDR, Client Expansion, Daily Prepper, SSG Engagements, Marketing Website) |
| **Platform / Admin** | User management, RBAC, integrations, MCP connections, audit log, custom fields, service catalog, data registry |

## Access tiers

Three broad tiers exist, with fine-grained RBAC on top:

- **Admin** (`is_system = true` role) — full access, `"*"` permission wildcard, can impersonate any user.
- **Member** (default) — standard access across modules per their specific custom role.
- **Viewer** (Read Only / External) — restricted read-only access; no MCP/AI access.

Cross-cutting capabilities:
- **Impersonation** — admins act as another user; real identity preserved for audit.
- **Demo Mode** — PII masking across CRM/wealth pages for screenshots/demos.

See [01-access-and-rbac.md](01-access-and-rbac.md) for the full permission model.
