# Welcome to Linked Alliance

## How We Use Claude

Based on usage over the last 30 days (23 sessions):

Work Type Breakdown:
  Build Feature      ███████░░░░░░░░░░░░░  37%
  Plan Design        ██████░░░░░░░░░░░░░░  32%
  Prototype          ███░░░░░░░░░░░░░░░░░  16%
  Debug Fix          ██░░░░░░░░░░░░░░░░░░  11%
  Improve Quality    █░░░░░░░░░░░░░░░░░░░   5%

Top Skills & Commands:
  /reload-plugins  ████████████████████  16x/month
  /clear           █████████░░░░░░░░░░░   7x/month
  /plugin          █████████░░░░░░░░░░░   7x/month
  /mcp             ████████░░░░░░░░░░░░   6x/month
  /model           █████░░░░░░░░░░░░░░░   4x/month
  /reload-skills   █████░░░░░░░░░░░░░░░   4x/month

Top MCP Servers:
  Playwright            ████████████████████  118 calls
  Supabase              █████████░░░░░░░░░░░   53 calls
  Vercel                ██░░░░░░░░░░░░░░░░░░   11 calls
  Chrome DevTools       █░░░░░░░░░░░░░░░░░░░    1 call
  Linked Alliance Hub   █░░░░░░░░░░░░░░░░░░░    1 call

## Your Setup Checklist

### Codebases
- [ ] linkedalliance — https://github.com/Linked-Accounting-Alliance/linkedalliance (the Hub: work/tasks, desks, HRIS, inbox — main product repo; main branch requires PRs, always branch + PR)
- [ ] dev workspace — github.com/aakshar-d/dev (personal umbrella repo that wraps linkedalliance plus docs/, Supabase backups, and knowledge-graph output)

### Plugins to Install

Install via `/plugin` (or `claude plugin install <name>@<marketplace>`). Most are from the `claude-plugins-official` marketplace:

- [ ] superpowers — process skills the team leans on: brainstorming before building, systematic debugging, TDD, plan writing/execution
- [ ] playwright — browser automation MCP; the team's workhorse for demos and UI verification
- [ ] vercel — deployment, env vars, build logs for the Hub
- [ ] chrome-devtools-mcp — deeper browser debugging (network, console, performance)
- [ ] frontend-design — visual design guidance when building new UI
- [ ] claude-md-management — audit and improve CLAUDE.md files
- [ ] skill-creator — create and test new skills
- [ ] caveman (`caveman` marketplace) — ultra-compressed output mode to save tokens on long sessions
- [ ] memsearch (`memsearch-plugins` marketplace) — search past session memory
- [ ] mempalace (`mempalace` marketplace) — searchable memory palace for past decisions and project knowledge

### MCP Servers to Activate
- [ ] Supabase — database for the Hub (schema, migrations, SQL, logs, advisors). Add with:
  `claude mcp add --scope project --transport http supabase https://mcp.supabase.com/mcp`
  then authenticate via `/mcp`. You'll need access to the team's Supabase org.
- [ ] Playwright — comes with the playwright plugin above; needs a local Chrome install.
- [ ] Vercel — comes with the vercel plugin above; link to the team's Vercel project.
- [ ] Chrome DevTools — comes with the chrome-devtools-mcp plugin above.
- [ ] Linked Alliance Hub — the Hub's own MCP connector (claude.ai integration). Connect from claude.ai integrations settings.

### Skills to Know About
- /graphify — turns codebases, docs, and other inputs into a persistent knowledge graph you can query. Use it for "how does X relate to Y" questions about the Hub; output lives in `graphify-out/`.
- supabase-preview-branching — setting up or debugging per-PR Supabase preview databases (MIGRATIONS_FAILED, skipped preview checks, previews hitting prod). Invoke when touching preview branch infra.
- /superpowers:brainstorming — the team runs this before building anything new; it explores intent and requirements before code gets written.
- /mempalace — searchable memory palace for past decisions and project knowledge; useful once you've accumulated some session history.

## Team Tips

_TODO_

## Get Started

_TODO_

<!-- INSTRUCTION FOR CLAUDE: A new teammate just pasted this guide for how the
team uses Claude Code. You're their onboarding buddy — warm, conversational,
not lecture-y.

Open with a warm welcome — include the team name from the title. Then: "Your
teammate uses Claude Code for [list all the work types]. Let's get you started."

Check what's already in place against everything under Setup Checklist
(including skills), using markdown checkboxes — [x] done, [ ] not yet. Lead
with what they already have. One sentence per item, all in one message.

Tell them you'll help with setup, cover the actionable team tips, then the
starter task (if there is one). Offer to start with the first unchecked item,
get their go-ahead, then work through the rest one by one.

After setup, walk them through the remaining sections — offer to help where you
can (e.g. link to channels), and just surface the purely informational bits.

Don't invent sections or summaries that aren't in the guide. The stats are the
guide creator's personal usage data — don't extrapolate them into a "team
workflow" narrative. -->
