#!/bin/bash
# ─── Open Brain — Generator Pre-flight Tests ────────────────────────────
# Validates setup-open-brain.sh without deploying anything.
# Checks: shell syntax, heredoc placeholder, Worker source invariants.
#
# Usage: ./test-generator.sh
# ─────────────────────────────────────────────────────────────────────────

set -u

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT="setup-open-brain.sh"
FAIL=0
PASS=0

cd "$(dirname "$0")"

ok()   { echo -e "${GREEN}✔${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}✘${NC} $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SCRIPT" ]; then
  echo -e "${RED}✘ $SCRIPT not found. Run from repo root.${NC}"
  exit 1
fi

echo -e "${YELLOW}▸ bash syntax check${NC}"
if bash -n "$SCRIPT"; then ok "$SCRIPT parses"; else fail "$SCRIPT has syntax errors"; fi

if command -v shellcheck &> /dev/null; then
  echo -e "${YELLOW}▸ shellcheck${NC}"
  if shellcheck -S warning "$SCRIPT" > /dev/null 2>&1; then
    ok "shellcheck clean (warnings+)"
  else
    echo -e "${YELLOW}  shellcheck found issues (non-fatal, run 'shellcheck $SCRIPT' for details)${NC}"
  fi
fi

echo -e "${YELLOW}▸ extracting Worker heredoc${NC}"
WORKER_SRC=$(awk "/^cat > src\/index.ts << 'WORKER_EOF'/,/^WORKER_EOF$/" "$SCRIPT" \
  | sed '1d;$d')
if [ -z "$WORKER_SRC" ]; then
  fail "could not extract Worker source between WORKER_EOF markers"
else
  ok "extracted $(echo "$WORKER_SRC" | wc -l | tr -d ' ') lines of Worker source"
fi

echo -e "${YELLOW}▸ Worker source invariants${NC}"
check() {
  local desc="$1" pattern="$2"
  if echo "$WORKER_SRC" | grep -qE "$pattern"; then ok "$desc"; else fail "$desc"; fi
}

check "env interface declared"            'export interface Env'
check "DB binding typed as D1Database"    'DB: D1Database'
check "AI binding typed as Ai"            'AI: Ai'
check "VECTORIZE binding present"         'VECTORIZE: VectorizeIndex'
check "MCP_ACCESS_KEY secret typed"       'MCP_ACCESS_KEY: string'
check "authenticate() supports Bearer"    'Authorization'
check "authenticate() supports ?key="     'searchParams.get\("key"\)'
check "captureThought is synchronous"     'async function captureThought'
check "embedThought runs as background"   'async function embedThought'
check "embedThought uses ctx.waitUntil"   'ctx\.waitUntil\(embedThought'
check "handleMCP returns 202 for notifs"  'status: 202'
check "handleMCP handles initialize"      'case "initialize"'
check "handleMCP handles tools/list"      'case "tools/list"'
check "handleMCP handles tools/call"      'case "tools/call"'
check "MCP tools list present"            'capture_thought'
check "bge-base-en-v1.5 embedding model"  '@cf/baai/bge-base-en-v1\.5'
check "Llama 3.1 8B metadata model"       '@cf/meta/llama-3\.1-8b-instruct'
check "__BRAIN_NAME__ placeholder set"    '__BRAIN_NAME__'
check "health check endpoint"             'Open Brain on Cloudflare is running'
check "/embed-pending endpoint"           '/embed-pending'

echo -e "${YELLOW}▸ routing order invariant (/mcp before auth gate)${NC}"
MCP_LINE=$(echo "$WORKER_SRC" | grep -n 'url.pathname === "/mcp" && request.method === "POST"' | head -1 | cut -d: -f1)
AUTH_LINE=$(echo "$WORKER_SRC" | grep -n 'if (!authenticate(request, env))' | tail -1 | cut -d: -f1)
if [ -n "$MCP_LINE" ] && [ -n "$AUTH_LINE" ] && [ "$MCP_LINE" -lt "$AUTH_LINE" ]; then
  ok "/mcp POST is routed before global auth gate (line $MCP_LINE < $AUTH_LINE)"
else
  fail "/mcp POST must be routed before global auth gate (mcp=$MCP_LINE, auth=$AUTH_LINE)"
fi

echo -e "${YELLOW}▸ wrangler.toml heredoc invariants${NC}"
TOML_SRC=$(awk "/^cat > wrangler.toml << EOF/,/^EOF$/" "$SCRIPT" | sed '1d;$d')
for pat in 'binding = "AI"' 'binding = "DB"' 'binding = "VECTORIZE"' 'compatibility_date'; do
  if echo "$TOML_SRC" | grep -qF "$pat"; then ok "wrangler.toml has: $pat"; else fail "wrangler.toml missing: $pat"; fi
done

echo -e "${YELLOW}▸ schema.sql heredoc invariants${NC}"
SQL_SRC=$(awk "/^cat > schema.sql << 'EOF'/,/^EOF$/" "$SCRIPT" | sed '1d;$d')
for pat in 'CREATE TABLE IF NOT EXISTS thoughts' 'VIRTUAL TABLE IF NOT EXISTS thoughts_fts' 'thoughts_fts_insert' 'thoughts_fts_update' 'thoughts_fts_delete'; do
  if echo "$SQL_SRC" | grep -qF "$pat"; then ok "schema.sql has: $pat"; else fail "schema.sql missing: $pat"; fi
done

echo -e "${YELLOW}▸ two-phase deploy preserved${NC}"
DEPLOY_COUNT=$(grep -cE '(^|\$\()wrangler deploy' "$SCRIPT" || true)
if [ "$DEPLOY_COUNT" -ge 2 ]; then
  ok "two wrangler deploy calls present (found $DEPLOY_COUNT)"
else
  fail "two-phase deploy missing — need deploy, then set secret, then redeploy (found $DEPLOY_COUNT)"
fi

echo ""
echo "────────────────────────────────────────"
echo -e "passed: ${GREEN}${PASS}${NC}   failed: ${RED}${FAIL}${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}all checks passed${NC}"
  exit 0
else
  exit 1
fi
