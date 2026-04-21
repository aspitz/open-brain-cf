# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Nature

This repo is **not** a Cloudflare Worker project — it is a **setup generator** for one. There is no `package.json`, `src/`, or build system at the root. The repo's three artifacts are:

- `setup-open-brain.sh` — bash generator that provisions Cloudflare infra (D1, Vectorize, Worker) and **emits a `<name>-worker/` sibling directory** containing the real `wrangler.toml`, `schema.sql`, and `src/index.ts`. The Worker source is heredoc'd inline inside this script (search `WORKER_EOF`).
- `open-brain-cloudflare.md` — the long-form, step-by-step manual build guide. Contains a reference copy of the Worker source.
- `README.md` — quick-start pointing users at the setup script.

When editing Worker behavior, **the canonical source is the heredoc in `setup-open-brain.sh`** (the script writes this verbatim to `src/index.ts`). Any change to Worker logic must be made there; the copy in `open-brain-cloudflare.md` is documentation and should be kept in sync as a secondary step. The generated `<name>-worker/` directory is disposable output — do not edit it and expect the change to persist across re-runs.

## Commands

The generator itself has no build/test suite. Typical usage:

```bash
./setup-open-brain.sh                 # provision with default name "open-brain"
./setup-open-brain.sh my-brain        # custom name (lowercase, alphanumeric + hyphens)
./setup-open-brain.sh --delete        # tear down default deployment
./setup-open-brain.sh --delete my-brain
```

Inside the generated `<name>-worker/` directory:

```bash
npm run deploy    # wrangler deploy
npm run dev       # wrangler dev (local preview)
npm run tail      # wrangler tail (live logs)

wrangler d1 execute <brain-name> --remote --file=schema.sql   # re-apply schema
wrangler d1 execute <brain-name> --remote --command="SELECT count(*) FROM thoughts;"
wrangler secret put MCP_ACCESS_KEY   # rotate access key; redeploy after
```

The setup script **requires two `wrangler deploy` calls** — one to create the Worker so secrets can be attached, then a second to publish with the secret bound. Preserve this two-phase deploy if editing the script.

## Architecture

The deployed system is a single Cloudflare Worker with three bindings (`DB` → D1, `AI` → Workers AI, `VECTORIZE` → Vectorize index) that serves both an **MCP JSON-RPC endpoint** (`POST /mcp`) and a **REST API** (`/capture`, `/search`, `/recent`, `/embed-pending`, `/slack`).

Critical invariants:

- **Capture is split sync/async by design.** `captureThought` writes to D1 and returns immediately; `embedThought` (embedding + metadata extraction + Vectorize upsert) runs via `ctx.waitUntil` so the client isn't blocked. Rows are inserted with `embedded=0` and flipped to `1` after the background job succeeds. If embedding fails, the row stays `embedded=0` and is retried via `POST /embed-pending`. **Do not collapse these two phases into a single synchronous flow** — it breaks the latency contract and the retry mechanism.
- **The `/mcp` route is intentionally positioned before the global `authenticate()` gate** so the MCP `initialize` / `tools/list` handshake works unauthenticated; auth is enforced per-tool inside `handleMCP` at the `tools/call` case. Moving `/mcp` behind the global auth check will break MCP client discovery.
- **Auth accepts both `Authorization: Bearer` and `?key=` query param.** The query-param path exists for MCP clients (e.g. `mcp-remote`) that can't set headers. Keep both.
- **JSON-RPC notifications (no `id`) must return `202` with an empty body**, never a JSON-RPC response. This is handled at the top of `handleMCP`.
- **Embedding dimensions (768) are locked to `@cf/baai/bge-base-en-v1.5`.** Swapping embedding models requires recreating the Vectorize index — it cannot be changed in place.
- **Metadata extraction is tolerant by design.** `extractMetadata` regex-matches `{…}` out of the Llama response and falls back to a default object on any parse error. Don't tighten this into a strict JSON parse; the 8B model occasionally wraps output in prose or fences.

Schema-level detail: FTS5 is kept in sync with the `thoughts` table via three triggers (`thoughts_fts_insert/update/delete`). If you add columns to `thoughts`, the FTS virtual table and triggers stay the same unless you want those columns searchable — FTS only indexes `content`.

## Editing Etiquette

- The `.omc/` directory is local tooling state (oh-my-claudecode); ignore it when reasoning about the project.
- There's no CI, linter, or test harness in this repo. Shell changes to `setup-open-brain.sh` should be verified with `bash -n setup-open-brain.sh` and, ideally, a dry run against a throwaway brain name.
- When the Worker source in the heredoc and in `open-brain-cloudflare.md` drift, the heredoc wins — the markdown is a teaching copy.
