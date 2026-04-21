# Open Brain on Cloudflare

This project is based on [OB1 by Nate B. Jones](https://github.com/NateBJones-Projects/OB1) — a Cloudflare-native rebuild of the same persistent AI memory idea, swapping Supabase + OpenRouter for Cloudflare D1, Vectorize, and Workers AI.

A one-click setup script and guide for deploying a personal AI memory system as a Cloudflare Worker. Capture thoughts, automatically generate semantic embeddings, and search by meaning — all running on Cloudflare's edge platform with D1, Vectorize, and Workers AI. Connects to AI clients via MCP.

## What It Does

- Stores thoughts in a D1 (SQLite) database with full-text search
- Generates 768-dimensional semantic embeddings via Workers AI (`@cf/baai/bge-base-en-v1.5`)
- Extracts metadata (type, topics, sentiment, priority) via Llama 3.1 8B
- Indexes embeddings in Vectorize for cosine-similarity search
- Exposes an MCP server for Claude Desktop, Claude Code, and other MCP clients
- Includes a REST API and optional Slack capture webhook

## Prerequisites

- A free [Cloudflare account](https://dash.cloudflare.com/sign-up)
- Node.js 18+
- npm

## Quick Start

Run this in any directory — it provisions everything and emits an `open-brain-worker/` folder beside it:

```bash
curl -fsSL https://raw.githubusercontent.com/aspitz/open-brain-cf/main/setup-open-brain.sh | bash
```

Pass a custom name by forwarding it through `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/aspitz/open-brain-cf/main/setup-open-brain.sh | bash -s -- my-brain
```

The script handles everything: D1 database creation, Vectorize index setup, Worker deployment, schema application, and secret configuration. Credentials are saved to `<name>-worker/credentials.txt`.

### Clone for Persistence

If you want the script available locally (e.g., to tear down later), clone instead:

```bash
git clone https://github.com/aspitz/open-brain-cf.git
cd open-brain-cf
./setup-open-brain.sh            # default name "open-brain"
./setup-open-brain.sh my-brain   # custom name
```

### Delete Everything

Tear-down has an interactive confirmation prompt, so run it from a local clone:

```bash
./setup-open-brain.sh --delete
./setup-open-brain.sh --delete my-brain
```

## Connecting AI Clients

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "open-brain": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote",
        "https://open-brain.YOUR_SUBDOMAIN.workers.dev/mcp?key=YOUR_ACCESS_KEY"
      ]
    }
  }
}
```

### Claude Code

Add to `.mcp.json`:

```json
{
  "mcpServers": {
    "open-brain": {
      "type": "sse",
      "url": "https://open-brain.YOUR_SUBDOMAIN.workers.dev/mcp?key=YOUR_ACCESS_KEY"
    }
  }
}
```

## REST API

All REST endpoints (except health check) require `Authorization: Bearer <key>`.

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/` | Health check |
| POST | `/capture` | Capture a thought (`{"content": "..."}`) |
| POST | `/search` | Semantic search (`{"query": "..."}`) |
| GET | `/recent?limit=20` | List recent thoughts |
| POST | `/embed-pending` | Retry failed embeddings |
| POST | `/mcp` | MCP JSON-RPC endpoint |

## MCP Tools

| Tool | Description |
|------|-------------|
| `capture_thought` | Save a thought with automatic embedding and metadata extraction |
| `search_thoughts` | Semantic search across all captured thoughts |
| `list_recent` | List most recent thoughts |

## Architecture

```
Client (Claude, Slack, REST)
  → Cloudflare Worker (MCP + REST router)
    → D1 (thought storage + full-text search)
    → Workers AI (embeddings + metadata extraction)
    → Vectorize (semantic vector index)
```

Capture is synchronous (D1 write returns immediately). Embedding and metadata extraction run in the background via `ctx.waitUntil()`.

## Cost

Cloudflare's free tier covers personal usage:

| Service | Free Tier |
|---------|-----------|
| Workers | 100,000 requests/day |
| D1 | 5M reads/day, 100K writes/day, 5 GB storage |
| Vectorize | 5M stored vector dimensions |
| Workers AI | 10,000 neurons/day |

## Testing

Two scripts verify different layers of the system. Run them from the repo root.

### `test-generator.sh` — pre-flight

Validates `setup-open-brain.sh` without deploying anything (syntax check, Worker heredoc invariants, `/mcp`-before-auth routing order, two-phase deploy preserved). Useful before committing changes to the generator.

```bash
./test-generator.sh
```

### `test-deployment.sh` — live smoke test

Hits a deployed Worker end-to-end: health, auth gate, capture round-trip, MCP `initialize`/`tools/list`/`tools/call`, and polls `/search` until the background embedding lands. Credentials are read from `<brain-name>-worker/credentials.txt` (written by the setup script) or from env vars.

```bash
./test-deployment.sh                       # default brain "open-brain"
./test-deployment.sh my-brain              # custom brain
WORKER_URL=https://… MCP_ACCESS_KEY=… ./test-deployment.sh   # explicit
```

## Documentation

See [open-brain-cloudflare.md](open-brain-cloudflare.md) for the full step-by-step build guide.

## License

MIT
