# Build Your Open Brain on Cloudflare

The same persistent memory system as Open Brain — one database, one AI gateway, semantic search — rebuilt entirely on Cloudflare's edge platform. No Supabase, no OpenRouter, no external dependencies. Everything runs on Cloudflare.

**What you'll build:**
- A D1 database to store your thoughts, metadata, and timestamps
- A Vectorize index for semantic (meaning-based) search
- Workers AI for embedding generation and metadata extraction — no external API keys needed
- A Cloudflare Worker that serves as your MCP server (read + write)
- A Slack capture channel for quick thought entry (optional)

**What you'll need:**
- A free Cloudflare account
- Node.js 18+ installed
- About 45 minutes

**Stack comparison:**

| Open Brain (Original) | Open Brain (Cloudflare) |
|---|---|
| Supabase PostgreSQL + pgvector | Cloudflare D1 + Vectorize |
| Supabase Edge Functions | Cloudflare Workers |
| OpenRouter (embeddings + LLM) | Workers AI (built-in, no API key) |
| Supabase Row Level Security | Worker-level auth with access key |
| Supabase Dashboard | Wrangler CLI + D1 Console |

---

## Credential Tracker

Copy this into a text file **right now**. Fill it in as you go. If you skip this, you'll hit Step 5 and realize you don't have your database ID from Step 2.

```
CLOUDFLARE OPEN BRAIN — CREDENTIALS
====================================
Cloudflare Account ID:    _______________
D1 Database Name:         open-brain
D1 Database ID:           _______________
Vectorize Index Name:     thoughts-index
MCP Access Key:           _______________
Slack Bot Token:          _______________  (optional)
Slack Signing Secret:     _______________  (optional)
Slack Channel ID:         _______________  (optional)
```

---

## Part 1: Capture — Store Thoughts with Semantic Embeddings

### Step 1: Install Wrangler and Log In

Wrangler is Cloudflare's CLI. It's how you create databases, deploy Workers, and manage everything.

```bash
npm install -g wrangler
wrangler login
```

This opens a browser window. Log in to your Cloudflare account and authorize Wrangler.

Get your Account ID from the Cloudflare dashboard (top right → your account → Overview). Paste it into the credential tracker.

✅ **Done when:** `wrangler whoami` shows your account name.

---

### Step 2: Create Your D1 Database

D1 is Cloudflare's serverless SQLite database. It stores your thoughts as text, metadata, and timestamps.

```bash
wrangler d1 create open-brain
```

This outputs a database ID. **Copy it into your credential tracker immediately.**

Now create the schema. Make a file called `schema.sql`:

```sql
-- Thoughts table: stores raw text, metadata, and timestamps
CREATE TABLE IF NOT EXISTS thoughts (
  id TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
  content TEXT NOT NULL,
  metadata TEXT DEFAULT '{}',
  source TEXT DEFAULT 'mcp',
  embedded INTEGER DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Index for time-based queries
CREATE INDEX IF NOT EXISTS idx_thoughts_created_at ON thoughts(created_at);

-- Index for source filtering
CREATE INDEX IF NOT EXISTS idx_thoughts_source ON thoughts(source);

-- Index for pending embedding jobs
CREATE INDEX IF NOT EXISTS idx_thoughts_embedded ON thoughts(embedded);

-- Full-text search as a fallback/complement to vector search
CREATE VIRTUAL TABLE IF NOT EXISTS thoughts_fts USING fts5(
  content,
  content_rowid='rowid'
);

-- Trigger to keep FTS in sync on insert
CREATE TRIGGER IF NOT EXISTS thoughts_fts_insert AFTER INSERT ON thoughts
BEGIN
  INSERT INTO thoughts_fts(rowid, content) VALUES (NEW.rowid, NEW.content);
END;

-- Trigger to keep FTS in sync on update
CREATE TRIGGER IF NOT EXISTS thoughts_fts_update AFTER UPDATE OF content ON thoughts
BEGIN
  DELETE FROM thoughts_fts WHERE rowid = OLD.rowid;
  INSERT INTO thoughts_fts(rowid, content) VALUES (NEW.rowid, NEW.content);
END;

-- Trigger to keep FTS in sync on delete
CREATE TRIGGER IF NOT EXISTS thoughts_fts_delete AFTER DELETE ON thoughts
BEGIN
  DELETE FROM thoughts_fts WHERE rowid = OLD.rowid;
END;
```

Apply it:

```bash
wrangler d1 execute open-brain --remote --file=schema.sql
```

✅ **Done when:** `wrangler d1 execute open-brain --remote --command="SELECT name FROM sqlite_master WHERE type='table';"` shows `thoughts` and `thoughts_fts`.

---

### Step 3: Create Your Vectorize Index

Vectorize stores the embeddings — 1,536-dimensional vectors that capture the *meaning* of each thought. This is what powers semantic search.

```bash
wrangler vectorize create thoughts-index \
  --dimensions=768 \
  --metric=cosine
```

> **Why 768 dimensions?** Workers AI's built-in embedding model (`@cf/baai/bge-base-en-v1.5`) outputs 768-dimensional vectors. If you later switch to an OpenAI-compatible model (1,536 dimensions), you'll need to recreate the index. 768 is efficient and performs well for personal knowledge bases.

✅ **Done when:** `wrangler vectorize list` shows `thoughts-index`.

---

### Step 4: Generate Your Access Key

Your MCP server will be a public URL. This key locks it down.

```bash
openssl rand -hex 32
```

Copy the output into your credential tracker under **MCP Access Key**.

---

### Step 5: Create the Worker

This is the brain of the system. One Worker handles both capture and retrieval.

> **Recommended:** Use `setup-open-brain.sh` to generate all project files automatically. The script produces the canonical, tested Worker code. The source below is a reference if you prefer to build manually.

```bash
mkdir open-brain-worker && cd open-brain-worker
npm init -y
```

Create `wrangler.toml`:

```toml
name = "open-brain"
main = "src/index.ts"
compatibility_date = "2024-12-01"
workers_dev = true
preview_urls = true

[ai]
binding = "AI"

[[d1_databases]]
binding = "DB"
database_name = "open-brain"
database_id = "YOUR_D1_DATABASE_ID"  # ← paste from credential tracker

[[vectorize]]
binding = "VECTORIZE"
index_name = "thoughts-index"
```

Create `src/index.ts`:

```typescript
export interface Env {
  DB: D1Database;
  AI: Ai;
  VECTORIZE: VectorizeIndex;
  MCP_ACCESS_KEY: string;
}

// ─── Auth ───────────────────────────────────────────────────────────────
function authenticate(request: Request, env: Env): boolean {
  // Check Authorization header first
  const authHeader = request.headers.get("Authorization");
  if (authHeader) {
    const token = authHeader.replace("Bearer ", "");
    if (token === env.MCP_ACCESS_KEY) return true;
  }
  // Fall back to query parameter (for MCP clients that don't support headers)
  const url = new URL(request.url);
  const keyParam = url.searchParams.get("key");
  if (keyParam === env.MCP_ACCESS_KEY) return true;
  return false;
}

// ─── Embedding Generation ───────────────────────────────────────────────
async function generateEmbedding(ai: Ai, text: string): Promise<number[]> {
  const result = await ai.run("@cf/baai/bge-base-en-v1.5", {
    text: [text],
  });
  return result.data[0];
}

// ─── Metadata Extraction ────────────────────────────────────────────────
async function extractMetadata(ai: Ai, content: string): Promise<object> {
  const result = await ai.run("@cf/meta/llama-3.1-8b-instruct", {
    messages: [
      {
        role: "system",
        content: `Extract metadata from the following thought. Return ONLY valid JSON with these fields:
          - type: one of "idea", "task", "observation", "memory", "question", "reference"
          - topics: array of 1-3 topic tags (lowercase, short)
          - people: array of any people mentioned (empty array if none)
          - sentiment: one of "positive", "negative", "neutral"
          - priority: one of "high", "medium", "low"
        Return ONLY the JSON object, no explanation.`,
      },
      { role: "user", content },
    ],
    max_tokens: 200,
  });

  try {
    const text = (result as any).response;
    // Extract JSON from response (handle markdown code blocks)
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
      return JSON.parse(jsonMatch[0]);
    }
    return { type: "observation", topics: [], people: [], sentiment: "neutral", priority: "medium" };
  } catch {
    return { type: "observation", topics: [], people: [], sentiment: "neutral", priority: "medium" };
  }
}

// ─── Capture a Thought (sync: D1 write, returns immediately) ────────────
async function captureThought(
  env: Env,
  content: string,
  source: string = "mcp"
): Promise<{ id: string }> {
  const id = crypto.randomUUID().replace(/-/g, "");

  // Synchronous: write to D1 immediately — thought is queryable via FTS and list
  await env.DB.prepare(
    `INSERT INTO thoughts (id, content, metadata, source, embedded, created_at, updated_at)
     VALUES (?, ?, '{}', ?, 0, datetime('now'), datetime('now'))`
  )
    .bind(id, content, source)
    .run();

  return { id };
}

// ─── Embed a Thought (async: embedding + metadata + vectorize) ──────────
async function embedThought(env: Env, id: string, content: string, source: string): Promise<void> {
  try {
    const [embedding, metadata] = await Promise.all([
      generateEmbedding(env.AI, content),
      extractMetadata(env.AI, content),
    ]);

    // Update D1 with extracted metadata and mark as embedded
    await env.DB.prepare(
      `UPDATE thoughts SET metadata = ?, embedded = 1, updated_at = datetime('now') WHERE id = ?`
    )
      .bind(JSON.stringify(metadata), id)
      .run();

    // Upsert vector into Vectorize
    await env.VECTORIZE.upsert([
      {
        id,
        values: embedding,
        metadata: {
          source,
          ...(metadata as Record<string, any>),
        },
      },
    ]);
  } catch (err) {
    console.error(`Failed to embed thought ${id}:`, err);
    // Thought remains in D1 with embedded=0 for retry
  }
}

// ─── Embed Any Pending Thoughts (batch) ─────────────────────────────────
async function embedPending(env: Env, limit: number = 10): Promise<number> {
  const { results } = await env.DB.prepare(
    `SELECT id, content, source FROM thoughts WHERE embedded = 0 ORDER BY created_at ASC LIMIT ?`
  )
    .bind(limit)
    .all();

  if (!results || results.length === 0) return 0;

  await Promise.all(
    results.map((r: any) => embedThought(env, r.id, r.content, r.source))
  );

  return results.length;
}

// ─── Search Thoughts ────────────────────────────────────────────────────
async function searchThoughts(
  env: Env,
  query: string,
  topK: number = 10
): Promise<any[]> {
  // Generate embedding for the query
  const queryEmbedding = await generateEmbedding(env.AI, query);

  // Search Vectorize for similar thoughts
  const vectorResults = await env.VECTORIZE.query(queryEmbedding, {
    topK,
    returnMetadata: "all",
  });

  if (!vectorResults.matches || vectorResults.matches.length === 0) {
    return [];
  }

  // Fetch full thought content from D1
  const ids = vectorResults.matches.map((m) => m.id);
  const placeholders = ids.map(() => "?").join(",");
  const { results } = await env.DB.prepare(
    `SELECT id, content, metadata, source, created_at FROM thoughts WHERE id IN (${placeholders})`
  )
    .bind(...ids)
    .all();

  // Merge vector scores with thought content
  const thoughtMap = new Map(results?.map((r: any) => [r.id, r]) || []);
  return vectorResults.matches
    .map((match) => {
      const thought = thoughtMap.get(match.id);
      if (!thought) return null;
      return {
        id: match.id,
        content: (thought as any).content,
        metadata: JSON.parse((thought as any).metadata || "{}"),
        source: (thought as any).source,
        created_at: (thought as any).created_at,
        score: match.score,
      };
    })
    .filter(Boolean);
}

// ─── List Recent Thoughts ───────────────────────────────────────────────
async function listRecent(env: Env, limit: number = 20): Promise<any[]> {
  const { results } = await env.DB.prepare(
    `SELECT id, content, metadata, source, created_at
     FROM thoughts ORDER BY created_at DESC LIMIT ?`
  )
    .bind(limit)
    .all();

  return (results || []).map((r: any) => ({
    ...r,
    metadata: JSON.parse(r.metadata || "{}"),
  }));
}

// ─── JSON-RPC Helper ────────────────────────────────────────────────────
function jsonrpc(id: any, result: any): Response {
  return Response.json({ jsonrpc: "2.0", id, result });
}

function jsonrpcError(id: any, code: number, message: string): Response {
  return Response.json({ jsonrpc: "2.0", id, error: { code, message } });
}

// ─── MCP Tool Definitions ───────────────────────────────────────────────
const MCP_TOOLS = [
  {
    name: "capture_thought",
    description:
      "Save a thought, idea, observation, or any piece of information to your Open Brain. The system will automatically generate a semantic embedding and extract metadata.",
    inputSchema: {
      type: "object",
      properties: {
        content: {
          type: "string",
          description: "The thought content to capture",
        },
        source: {
          type: "string",
          description: "Where this thought came from (e.g., 'claude', 'chatgpt', 'manual')",
          default: "mcp",
        },
      },
      required: ["content"],
    },
  },
  {
    name: "search_thoughts",
    description:
      "Search your Open Brain by meaning. Returns thoughts semantically similar to your query, ranked by relevance.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "What you're looking for — natural language works best",
        },
        limit: {
          type: "number",
          description: "Maximum number of results (default 10)",
          default: 10,
        },
      },
      required: ["query"],
    },
  },
  {
    name: "list_recent",
    description:
      "List your most recent thoughts, newest first.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "number",
          description: "Number of thoughts to return (default 20)",
          default: 20,
        },
      },
    },
  },
];

// ─── MCP Protocol Handler ───────────────────────────────────────────────
async function handleMCP(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const body: any = await request.json();
  const { method, params, id, jsonrpc: rpcVersion } = body;

  // Handle notifications (no id = notification, no response expected)
  if (id === undefined || id === null) {
    // notifications/initialized, notifications/cancelled, etc.
    return new Response(null, { status: 202 });
  }

  switch (method) {
    case "initialize":
      return jsonrpc(id, {
        protocolVersion: "2025-11-25",
        capabilities: {
          tools: { listChanged: false },
        },
        serverInfo: {
          name: "open-brain",
          version: "1.0.0",
        },
      });

    case "ping":
      return jsonrpc(id, {});

    case "tools/list":
      return jsonrpc(id, { tools: MCP_TOOLS });

    case "tools/call": {
      // Auth required for tool calls
      if (!authenticate(request, env)) {
        return jsonrpcError(id, -32600, "Unauthorized");
      }
      const toolName = params?.name;
      const args = params?.arguments || {};

      switch (toolName) {
        case "capture_thought": {
          const source = args.source || "mcp";
          const result = await captureThought(env, args.content, source);
          // Embed in background — response returns immediately
          ctx.waitUntil(embedThought(env, result.id, args.content, source));
          return jsonrpc(id, {
            content: [
              {
                type: "text",
                text: `Thought captured (id: ${result.id}). Embedding in background — semantic search available shortly.`,
              },
            ],
          });
        }

        case "search_thoughts": {
          const results = await searchThoughts(env, args.query, args.limit || 10);
          if (results.length === 0) {
            return jsonrpc(id, {
              content: [
                { type: "text", text: "No matching thoughts found." },
              ],
            });
          }
          const formatted = results
            .map(
              (r: any, i: number) =>
                `${i + 1}. [${r.score.toFixed(3)}] (${r.created_at}) ${r.content}`
            )
            .join("\n\n");
          return jsonrpc(id, {
            content: [{ type: "text", text: formatted }],
          });
        }

        case "list_recent": {
          const results = await listRecent(env, args.limit || 20);
          if (results.length === 0) {
            return jsonrpc(id, {
              content: [{ type: "text", text: "No thoughts captured yet." }],
            });
          }
          const formatted = results
            .map(
              (r: any, i: number) =>
                `${i + 1}. (${r.created_at}) [${r.source}] ${r.content}`
            )
            .join("\n\n");
          return jsonrpc(id, {
            content: [{ type: "text", text: formatted }],
          });
        }

        default:
          return jsonrpcError(id, -32601, `Unknown tool: ${toolName}`);
      }
    }

    default:
      return jsonrpcError(id, -32601, `Method not found: ${method}`);
  }
}

// ─── Main Router ────────────────────────────────────────────────────────
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === "/" && request.method === "GET") {
      return new Response("Open Brain on Cloudflare is running.", { status: 200 });
    }

    // OAuth discovery — return 404 so mcp-remote skips OAuth
    if (url.pathname.startsWith("/.well-known/")) {
      return new Response("Not found", { status: 404 });
    }

    // MCP endpoint — handle GET for SSE transport discovery
    if (url.pathname === "/mcp" && request.method === "GET") {
      return new Response("Method not allowed", { status: 405 });
    }

    // MCP endpoint — handle DELETE for session cleanup
    if (url.pathname === "/mcp" && request.method === "DELETE") {
      return new Response(null, { status: 200 });
    }

    // MCP endpoint — before auth so initialize handshake works
    if (url.pathname === "/mcp" && request.method === "POST") {
      return handleMCP(request, env, ctx);
    }

    // All other routes require auth
    if (!authenticate(request, env)) {
      return Response.json({ error: "Unauthorized" }, { status: 401 });
    }

    // REST: Capture
    if (url.pathname === "/capture" && request.method === "POST") {
      const { content, source } = (await request.json()) as any;
      if (!content) {
        return Response.json({ error: "content is required" }, { status: 400 });
      }
      const src = source || "api";
      const result = await captureThought(env, content, src);
      ctx.waitUntil(embedThought(env, result.id, content, src));
      return Response.json({ ...result, status: "captured, embedding in background" });
    }

    // REST: Search
    if (url.pathname === "/search" && request.method === "POST") {
      const { query, limit } = (await request.json()) as any;
      if (!query) {
        return Response.json({ error: "query is required" }, { status: 400 });
      }
      const results = await searchThoughts(env, query, limit || 10);
      return Response.json({ results });
    }

    // REST: Recent
    if (url.pathname === "/recent" && request.method === "GET") {
      const limit = parseInt(url.searchParams.get("limit") || "20");
      const results = await listRecent(env, limit);
      return Response.json({ results });
    }

    // REST: Process pending embeddings (retry failed or batched)
    if (url.pathname === "/embed-pending" && request.method === "POST") {
      const limit = parseInt(url.searchParams.get("limit") || "10");
      const count = await embedPending(env, limit);
      return Response.json({ processed: count });
    }

    // Slack webhook (optional — for Slack capture)
    if (url.pathname === "/slack" && request.method === "POST") {
      return handleSlack(request, env);
    }

    return Response.json({ error: "Not found" }, { status: 404 });
  },
};

// ─── Slack Handler (Optional) ───────────────────────────────────────────
async function handleSlack(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const params = new URLSearchParams(body);

  // Handle Slack URL verification challenge
  try {
    const json = JSON.parse(body);
    if (json.type === "url_verification") {
      return new Response(json.challenge, { status: 200 });
    }

    // Handle event callbacks
    if (json.type === "event_callback" && json.event?.type === "message") {
      const event = json.event;

      // Skip bot messages and edits
      if (event.bot_id || event.subtype) {
        return new Response("ok", { status: 200 });
      }

      const content = event.text;
      if (content) {
        await captureThought(env, content, "slack");
      }
    }
  } catch {
    // Not JSON — ignore
  }

  return new Response("ok", { status: 200 });
}
```

---

### Step 6: Deploy and Set Your Secret

```bash
# Deploy the Worker first
wrangler deploy

# Then set the access key as a secret
wrangler secret put MCP_ACCESS_KEY
# Paste your access key from the credential tracker when prompted

# Redeploy so the secret is live immediately
wrangler deploy
```

The second deploy picks up your secret. Wrangler will output your Worker URL. It looks like:
```
https://open-brain.YOUR_SUBDOMAIN.workers.dev
```

Test it:

```bash
# Health check
curl https://open-brain.YOUR_SUBDOMAIN.workers.dev/

# Capture a thought
curl -X POST https://open-brain.YOUR_SUBDOMAIN.workers.dev/capture \
  -H "Authorization: Bearer YOUR_ACCESS_KEY" \
  -H "Content-Type: application/json" \
  -d '{"content": "Testing my Open Brain on Cloudflare. This is my first thought."}'

# Search
curl -X POST https://open-brain.YOUR_SUBDOMAIN.workers.dev/search \
  -H "Authorization: Bearer YOUR_ACCESS_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "first thought"}'
```

✅ **Done when:** You can capture a thought and search for it by meaning.

---

## Part 2: Retrieval — Connect Your AI Tools via MCP

### Connecting Claude Desktop

Open your Claude Desktop config file:

- **Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`

Add this MCP server configuration:

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

Restart Claude Desktop. You should see the Open Brain tools available.

### Connecting Claude Code

In your project's `.mcp.json` or Claude Code settings, add:

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

### Test It

In Claude (Desktop or Code), try:

> "Save this thought to my Open Brain: I'm exploring how to build a subconscious layer for AI memory systems using Cloudflare Workers."

Then:

> "Search my Open Brain for anything about memory systems."

✅ **Done when:** You can capture and search thoughts from inside your AI client.

---

## Part 3 (Optional): Slack Capture

If you want a quick-capture channel outside your AI tools.

### Create a Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**
2. Name it "Open Brain" and pick your workspace
3. **OAuth & Permissions** → Add Bot Token Scopes:
   - `channels:history`
   - `channels:read`
4. **Install to Workspace** → Copy the **Bot User OAuth Token** into your credential tracker
5. **Event Subscriptions** → Enable → Set Request URL to:
   ```
   https://open-brain.YOUR_SUBDOMAIN.workers.dev/slack
   ```
6. Subscribe to bot events: `message.channels`
7. Invite the bot to your capture channel: `/invite @Open Brain`

Get your channel ID (right-click channel name → View channel details → copy the ID at the bottom).

Now every message you type in that channel gets automatically embedded and stored.

✅ **Done when:** You type a message in Slack and it appears when you search via MCP.

---

## How It Works Under the Hood

**When you capture a thought:**

```
Your AI client → POST /mcp (capture_thought)
  → SYNCHRONOUS (instant):
      → Write thought text to D1 with embedded=0
      → Return confirmation immediately
  → BACKGROUND (via ctx.waitUntil):
      → Generate embedding via Workers AI (768-dim, @cf/baai/bge-base-en-v1.5)
      → Extract metadata via Workers AI (Llama 3.1 8B)
      → Update D1 row with metadata, set embedded=1
      → Upsert embedding into Vectorize
```

The thought is queryable via full-text search and `list_recent` immediately. Semantic search becomes available once the background embedding completes (a few seconds). If embedding fails, the thought stays in D1 with `embedded=0` and can be retried via the `/embed-pending` endpoint.

**When you search:**

```
Your AI client → POST /mcp (search_thoughts)
  → Worker generates embedding of your query via Workers AI
  → Vectorize finds most similar vectors (cosine similarity)
  → Worker fetches full thought content from D1 by IDs
  → Results returned ranked by semantic similarity
```

**Why this is different from keyword search:** "Sarah's thinking about leaving" and "What did I note about career changes?" match semantically even though they share zero keywords. The embedding captures meaning, not words.

---

## Cost

Cloudflare's free tier covers a surprising amount:

| Service | Free Tier |
|---|---|
| Workers | 100,000 requests/day |
| D1 | 5M reads/day, 100K writes/day, 5 GB storage |
| Vectorize | 5M stored vector dimensions |
| Workers AI | 10,000 neurons/day |

For a personal Open Brain, the free tier will last you a long time. At heavy usage, the paid Workers plan ($5/month) removes most limits.

---

## What You Just Built

You stood up a serverless database on Cloudflare's global edge network. You created a vector index for semantic search. You deployed a Worker that generates embeddings and extracts metadata using on-device AI — no external API keys, no OpenRouter bill, no third-party dependencies. You connected it to your AI tools via MCP.

Everything runs on one platform. Compute and storage are colocated. There's no cold-start latency hitting an external database. And because it's Cloudflare, your brain runs in 300+ data centers worldwide.

---

## What's Next

This is the foundation. From here you can:

- **Build extensions:** Household knowledge, CRM, meal planning — same patterns as OB1's extensions, but on Cloudflare
- **Add a dashboard:** Deploy a Pages site that reads from D1 and lets you browse your brain visually
- **Hybrid search:** Combine Vectorize semantic search with D1 full-text search for best-of-both retrieval
- **Switch embedding models:** Workers AI supports multiple models; you can upgrade without changing infrastructure

---

## Troubleshooting

**"Vectorize query returned no results"**
If you just captured your first thought, give it a few seconds. Vectorize indexing is near-instant but not synchronous. Also check that your embedding dimensions match (768 for bge-base-en-v1.5).

**"Workers AI returned an error"**
Check your Workers AI usage in the Cloudflare dashboard. The free tier has a daily neuron limit. If you're hitting it, consider batching captures or upgrading to the paid plan.

**"D1 query failed"**
Run `wrangler d1 execute open-brain --remote --command="SELECT count(*) FROM thoughts;"` to verify your schema is set up correctly.

**"MCP connection failed in Claude Desktop"**
Double-check the URL and access key in your config. Restart Claude Desktop completely (not just close the window). Check `wrangler tail` to see if requests are reaching your Worker.

**"Slack messages aren't being captured"**
Verify Event Subscriptions shows a green checkmark for your Request URL. Make sure the bot is invited to the channel. Check `wrangler tail` for incoming Slack events.
