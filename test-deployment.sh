#!/bin/bash
# ─── Open Brain — Deployment Smoke Tests ────────────────────────────────
# Hits a live Worker and verifies the REST + MCP surface end-to-end.
# Captures a uniquely-tagged test thought, polls until it's embedded,
# then searches for it.
#
# Usage:
#   ./test-deployment.sh                    # reads ./open-brain-worker/credentials.txt
#   ./test-deployment.sh my-brain           # reads ./my-brain-worker/credentials.txt
#   WORKER_URL=... MCP_ACCESS_KEY=... ./test-deployment.sh   # explicit
# ─────────────────────────────────────────────────────────────────────────

set -u

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

BRAIN_NAME="${1:-open-brain}"
CRED_FILE="${BRAIN_NAME}-worker/credentials.txt"

FAIL=0
PASS=0

ok()   { echo -e "${GREEN}✔${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}✘${NC} $1"; [ -n "${2:-}" ] && echo "   $2"; FAIL=$((FAIL + 1)); }

# ─── Load Credentials ───────────────────────────────────────────────────
if [ -z "${WORKER_URL:-}" ] || [ -z "${MCP_ACCESS_KEY:-}" ]; then
  if [ -f "$CRED_FILE" ]; then
    echo -e "${YELLOW}▸ reading credentials from $CRED_FILE${NC}"
    WORKER_URL=$(grep '^Worker URL:' "$CRED_FILE" | awk '{print $NF}')
    MCP_ACCESS_KEY=$(grep '^MCP Access Key:' "$CRED_FILE" | awk '{print $NF}')
  else
    echo -e "${RED}✘ credentials not found${NC}"
    echo "   expected $CRED_FILE, or set WORKER_URL and MCP_ACCESS_KEY env vars"
    exit 1
  fi
fi

if [ -z "${WORKER_URL:-}" ] || [ -z "${MCP_ACCESS_KEY:-}" ]; then
  echo -e "${RED}✘ could not determine WORKER_URL and MCP_ACCESS_KEY${NC}"
  exit 1
fi

echo -e "${GREEN}worker:${NC} $WORKER_URL"
echo ""

# ─── Helpers ────────────────────────────────────────────────────────────
http() {
  # http METHOD PATH [body] [auth?]  -> writes "<code>\n<body>" to stdout
  local method="$1" path="$2" body="${3:-}" auth="${4:-yes}"
  local args=(-s -o /tmp/ob_body.$$ -w '%{http_code}' -X "$method" "$WORKER_URL$path")
  [ "$auth" = "yes" ] && args+=(-H "Authorization: Bearer $MCP_ACCESS_KEY")
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" -d "$body")
  local code
  code=$(curl "${args[@]}")
  echo "$code"
  cat /tmp/ob_body.$$
  rm -f /tmp/ob_body.$$
}

expect_code() {
  local desc="$1" expected="$2" actual="$3" body="$4"
  if [ "$actual" = "$expected" ]; then
    ok "$desc ($actual)"
  else
    fail "$desc — expected $expected, got $actual" "$body"
  fi
}

# ─── Tests ──────────────────────────────────────────────────────────────
MARKER="openbrain-smoketest-$(date +%s)-$RANDOM"

echo -e "${YELLOW}▸ REST: health${NC}"
RESP=$(http GET / "" no); CODE=${RESP%%$'\n'*}; BODY=${RESP#*$'\n'}
expect_code "GET / returns 200"            200 "$CODE" "$BODY"
if echo "$BODY" | grep -q "running"; then ok "health body mentions 'running'"; else fail "health body missing 'running'" "$BODY"; fi

echo -e "${YELLOW}▸ REST: auth gate${NC}"
RESP=$(http GET /recent "" no); CODE=${RESP%%$'\n'*}; BODY=${RESP#*$'\n'}
expect_code "GET /recent without auth → 401" 401 "$CODE" "$BODY"

RESP=$(http GET "/recent?limit=5"); CODE=${RESP%%$'\n'*}; BODY=${RESP#*$'\n'}
expect_code "GET /recent with auth → 200"    200 "$CODE" "$BODY"

echo -e "${YELLOW}▸ REST: capture${NC}"
RESP=$(http POST /capture "{\"content\":\"$MARKER test thought from smoke test\",\"source\":\"smoketest\"}")
CODE=${RESP%%$'\n'*}; BODY=${RESP#*$'\n'}
expect_code "POST /capture → 200" 200 "$CODE" "$BODY"
THOUGHT_ID=$(echo "$BODY" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
if [ -n "$THOUGHT_ID" ]; then ok "capture returned id: $THOUGHT_ID"; else fail "capture response missing id" "$BODY"; fi

echo -e "${YELLOW}▸ REST: recent contains captured thought${NC}"
RESP=$(http GET "/recent?limit=10"); BODY=${RESP#*$'\n'}
if echo "$BODY" | grep -q "$MARKER"; then ok "captured thought appears in /recent"; else fail "captured thought missing from /recent" "$BODY"; fi

echo -e "${YELLOW}▸ MCP: initialize (no auth)${NC}"
RESP=$(http POST /mcp '{"jsonrpc":"2.0","id":1,"method":"initialize"}' no)
CODE=${RESP%%$'\n'*}; BODY=${RESP#*$'\n'}
expect_code "POST /mcp initialize → 200" 200 "$CODE" "$BODY"
if echo "$BODY" | grep -q '"protocolVersion"'; then ok "initialize returned protocolVersion"; else fail "initialize missing protocolVersion" "$BODY"; fi

echo -e "${YELLOW}▸ MCP: tools/list (no auth)${NC}"
RESP=$(http POST /mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' no)
BODY=${RESP#*$'\n'}
for tool in capture_thought search_thoughts list_recent; do
  if echo "$BODY" | grep -q "\"$tool\""; then ok "tools/list includes $tool"; else fail "tools/list missing $tool" "$BODY"; fi
done

echo -e "${YELLOW}▸ MCP: tools/call rejects unauthed request${NC}"
RESP=$(http POST /mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_recent","arguments":{}}}' no)
BODY=${RESP#*$'\n'}
if echo "$BODY" | grep -q 'Unauthorized'; then ok "tools/call without auth returns Unauthorized"; else fail "tools/call without auth should return Unauthorized" "$BODY"; fi

echo -e "${YELLOW}▸ MCP: tools/call list_recent (with auth)${NC}"
RESP=$(http POST /mcp '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_recent","arguments":{"limit":5}}}')
CODE=${RESP%%$'\n'*}; BODY=${RESP#*$'\n'}
expect_code "tools/call list_recent → 200" 200 "$CODE" "$BODY"
if echo "$BODY" | grep -q "$MARKER"; then ok "list_recent via MCP includes the captured thought"; else fail "list_recent via MCP missing the captured thought" "$BODY"; fi

echo -e "${YELLOW}▸ Embedding: poll until background embed completes (up to 30s)${NC}"
SEARCH_HIT=0
for i in $(seq 1 15); do
  sleep 2
  RESP=$(http POST /search "{\"query\":\"$MARKER\",\"limit\":5}")
  BODY=${RESP#*$'\n'}
  if echo "$BODY" | grep -q "$MARKER"; then
    ok "semantic search returned the captured thought after ${i}x2s poll"
    SEARCH_HIT=1
    break
  fi
done
if [ "$SEARCH_HIT" -eq 0 ]; then
  fail "semantic search never returned the captured thought (Vectorize may be lagging or embedding failed)"
  echo -e "${YELLOW}   try: curl -X POST -H 'Authorization: Bearer \$KEY' $WORKER_URL/embed-pending${NC}"
fi

echo -e "${YELLOW}▸ REST: embed-pending endpoint reachable${NC}"
RESP=$(http POST /embed-pending); CODE=${RESP%%$'\n'*}; BODY=${RESP#*$'\n'}
expect_code "POST /embed-pending → 200" 200 "$CODE" "$BODY"

echo ""
echo "────────────────────────────────────────"
echo -e "passed: ${GREEN}${PASS}${NC}   failed: ${RED}${FAIL}${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}deployment healthy${NC}"
  exit 0
else
  exit 1
fi
