# PromptForge

AI-powered prompt optimization platform. Paste any prompt — get back a structured, token-efficient version optimized for GPT-4o, Claude, Gemini, and 12+ models. Average **40% token reduction** without losing intent.

---

## The Problem

Bad prompts waste tokens, get inconsistent results, and cost more money. Most people write prompts like they're texting a friend. LLMs respond better to structured, precise instructions.

PromptForge fixes this automatically.

---

## How It Works

```
User Prompt
     ↓
Token Count Check (plan limit gate)
     ↓
SHA-256 Cache Lookup (Redis) ──hit──→ Return cached result instantly
     ↓ miss
Build Meta-Prompt (model-specific system prompt)
     ↓
AI Provider (Gemini 1.5 Pro → GPT-4o fallback)
     ↓
Score Output (0–100 quality score)
     ↓
Parse Structure (detect RCTF / bullets / sections)
     ↓
Save to Supabase + pgvector embedding
     ↓
SSE Stream result back to client
```

### RCTF Structuring
Every optimized prompt gets restructured into:
- **R** — Role (who the AI should be)
- **C** — Context (background information)
- **T** — Task (what exactly to do)
- **F** — Format (how to respond)

---

## Optimization Pipeline (Code)

### Core Engine — `optimizer.ts`
```typescript
// 1. Validate input + check plan token limits
// 2. Cache lookup via SHA-256(prompt + model)
// 3. Call AI with model-specific meta-prompt
// 4. Score quality (0–100)
// 5. Parse structure type
// 6. Cache result for 24h
// 7. Return OptimizationResult
```

### API Route — `route.ts` (Next.js App Router)
```
POST /api/forge
  → Auth (Supabase)
  → Rate limit (per user, Redis)
  → Plan check (model allowed?)
  → Usage limit (monthly quota)
  → Concurrency lock (1 active job/user)
  → Stream SSE: analyzing → saving → result → done
```

### SSE Event Flow
```json
{ "type": "progress", "step": "analyzing", "pct": 10 }
{ "type": "progress", "step": "saving",    "pct": 85 }
{ "type": "result",   "data": { ... }                }
{ "type": "done"                                      }
```

---

## Database Schema

### Tables
| Table | Purpose |
|-------|---------|
| `users` | Auth, plan, Stripe IDs, referral code |
| `prompt_optimizations` | Every optimization with tokens, score, embedding |
| `usage_records` | Monthly usage per user |

### Key Design Decisions
- `savings_pct` — **generated column** (computed from token counts, never stale)
- `embedding VECTOR(1536)` — pgvector for semantic search across prompt history
- `share_id TEXT UNIQUE` — short ID for public share pages
- `referral_code` — auto-generated hex on user creation

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Frontend | Next.js 14 App Router, TypeScript, Tailwind CSS |
| Database | Supabase (PostgreSQL + pgvector extension) |
| Auth | Supabase Auth |
| Cache | Upstash Redis (results + locks + rate limits) |
| Queue | BullMQ + ioredis (async side-effects) |
| AI Providers | Gemini 1.5 Pro (primary) → GPT-4o (fallback) → Claude 3.5 |
| Payments | Stripe (subscriptions + webhooks) |
| Email | Resend |
| Monitoring | Pino structured logs, PostHog analytics, Sentry errors |
| Web Deploy | Vercel |
| Worker Deploy | Fly.io |
| Monorepo | Turborepo + pnpm workspaces |

---

## Monorepo Structure

```
promptforge/
├── apps/
│   ├── web/              # Next.js 14 — main web app
│   ├── workers/          # BullMQ processors — runs on Fly.io
│   ├── chrome-ext/       # Chrome Extension (Manifest V3)
│   └── vscode-ext/       # VS Code Extension
│
├── packages/
│   ├── ai-engine/        # PromptOptimizer class + provider registry
│   ├── config/           # Plan limits, model allowlists, env schema
│   ├── db/               # Supabase client, queries, migrations
│   ├── errors/           # Typed error classes (AuthError, UsageLimitError...)
│   ├── logger/           # Pino structured logger
│   ├── queue/            # BullMQ queue + job definitions
│   ├── redis/            # Upstash client, cache helpers, rate limiter
│   ├── stripe/           # Subscription management
│   ├── token-counter/    # tiktoken + rough count approximation
│   ├── types/            # Shared TypeScript interfaces
│   └── ui/               # Shared React components
│
└── infrastructure/
    ├── fly/fly.toml      # Worker process config
    └── terraform/        # IaC for cloud resources
```

---

## Plans

| | Free | Pro ($12/mo) | Team ($49/mo) |
|--|------|-------------|--------------|
| Optimizations | 25/mo | 500/mo | Unlimited |
| Models | 3 | All 12 | All + Early Access |
| Shareable pages | No | Yes | Yes |
| API access | No | No | Yes |
| History | 7 days | Unlimited | Unlimited |

### Supported Models
`gpt-4o` · `gpt-4o-mini` · `gpt-4-turbo` · `gpt-3.5-turbo` · `gemini-1.5-pro` · `gemini-1.5-flash` · `gemini-2.0` · `claude-3-5-sonnet` · `claude-3-opus` · `claude-3-haiku` · `general`

---

## Extensions

### Chrome Extension
Injects a **⚡ Forge** button directly into ChatGPT, Claude, and Gemini interfaces. Optimize prompts without leaving the tab.

### VS Code Extension
`Ctrl+Shift+P` → "Forge Prompt" — optimize the selected text in your editor. Ideal for system prompts in code.

---

## Quick Start

```bash
# 1. Install
pnpm install

# 2. Environment
cp .env.example .env.local
# Fill in: Supabase, Upstash, Stripe, Gemini, OpenAI, Resend keys

# 3. Database
# Run in Supabase SQL Editor:
# packages/db/migrations/001_initial_schema.sql
# packages/db/migrations/002_search_function.sql

# 4. Dev
pnpm dev
```

### Key Environment Variables
```bash
GEMINI_API_KEY=               # Primary AI provider
OPENAI_API_KEY=               # Fallback + embeddings
NEXT_PUBLIC_SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
UPSTASH_REDIS_REST_URL=
UPSTASH_REDIS_REST_TOKEN=
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=
RESEND_API_KEY=
```

---

## Deployment

```bash
# Web
vercel deploy --prod

# Workers
flyctl deploy --app promptforge-workers

# Chrome Extension → upload dist/ to Chrome Web Store
pnpm --filter @promptforge/chrome-ext build

# VS Code Extension → package with vsce
pnpm --filter promptforge-vscode compile
```

---

## Economics

```
10,000 MAU · 5% Pro conversion = 500 paying users

Revenue:      500 × $12 = $6,000/mo
AI costs:     ~$5–10/mo  (40% Redis cache hit rate)
Infra:        ~$60/mo    (Vercel + Fly.io + Upstash)

Gross margin: ~98%
```

The cache is the key — identical prompts never hit the AI twice. SHA-256 hash of `prompt + targetModel` as the cache key.

---

*Built by SR MAEIN · TypeScript · Next.js 14 · Supabase · Upstash · Stripe · Turborepo*
