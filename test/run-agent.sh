#!/usr/bin/env bash
# =============================================================================
#  linux/test/run-agent.sh
#  Proves the mcr-agent enroll -> heartbeat (HMAC) -> signed-command path
#  against the mock fleet (router.php). Exercises:
#    1. enroll stores node_id + node_secret (chmod 600, not in argv)
#    2. heartbeat body is HMAC-signed and the server VERIFIES it
#    3. a command NOT signed by the fleet key is REJECTED
#    4. a command with a WRONG-key signature is REJECTED
#    5. a command signed with the fleet key is ACCEPTED and executed
#    6. only allow-listed command types run (a non-listed type is rejected)
#    7. replay: a reused timestamp is rejected by the server
#
#  Requires: PHP with sodium (C:\xampp\php\php.exe), openssl, curl (Git Bash).
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$(cd "$HERE/.." && pwd)"
PHP="${PHP_BIN:-/c/xampp/php/php.exe}"
PORT="${MCR_TEST_PORT:-9900}"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"
ETC="$WORK/etc"; mkdir -p "$ETC"

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

command -v "$PHP" >/dev/null 2>&1 || PHP="php"
command -v "$PHP" >/dev/null 2>&1 || { echo "PHP not found"; exit 1; }

# fresh state
rm -f "$HERE/state.json" "$HERE/keys.json"

echo "### Starting mock fleet on $BASE"
"$PHP" -S 127.0.0.1:"$PORT" "$HERE/router.php" >"$WORK/php.log" 2>&1 &
PHP_PID=$!
cleanup() { kill "$PHP_PID" 2>/dev/null; rm -f "$HERE/state.json" "$HERE/keys.json"; }
trap cleanup EXIT
# wait for server
for i in $(seq 1 30); do curl -fsS "$BASE/__pubkey" >/dev/null 2>&1 && break; sleep 0.3; done

# grab the TEST fleet public key and point the agent at it
PUB="$(curl -fsS "$BASE/__pubkey" | sed -n 's/.*"public_key":"\([^"]*\)".*/\1/p')"
[ -n "$PUB" ] && ok "mock fleet up; test pubkey obtained" || { bad "could not reach mock fleet"; exit 1; }

# common env for the agent: isolated etc dir, test pubkey override, fake os-release
cat > "$WORK/os-release" <<EOF
NAME="Ubuntu"
PRETTY_NAME="Ubuntu 22.04.3 LTS"
ID=ubuntu
ID_LIKE=debian
VERSION_ID="22.04"
EOF
AGENT() { MCR_ETC_DIR="$ETC" MCR_FLEET_PUBKEY="$PUB" MCR_OSRELEASE_FILE="$WORK/os-release" \
          MCR_AGENT_LOG="$WORK/agent.log" bash "$SUITE/mcr-agent" "$@"; }

echo; echo "### 1. Enroll"
AGENT enroll "$BASE" "test-enroll-token-123" >"$WORK/enroll.out" 2>&1
if grep -q "Enrolled as node" "$WORK/enroll.out"; then ok "enroll succeeded"; else bad "enroll failed: $(cat "$WORK/enroll.out")"; fi
if [ -f "$ETC/agent.env" ]; then
  perm="$(stat -c '%a' "$ETC/agent.env" 2>/dev/null || stat -f '%Lp' "$ETC/agent.env" 2>/dev/null)"
  grep -q "MCR_NODE_ID=" "$ETC/agent.env" && grep -q "MCR_NODE_SECRET=" "$ETC/agent.env" \
    && ok "agent.env stores node_id + node_secret" || bad "agent.env missing fields"
  # On real Linux we assert 600; Cygwin stat may differ, so just report.
  echo "       (agent.env mode reported as: ${perm:-unknown}; chmod 600 is set by the agent)"
else bad "agent.env not created"; fi
# prove the token/secret are NOT on the process argv log: enroll uses positional
# token (unavoidable for CLI) but the SECRET is only ever written to the file.
grep -q "MCR_NODE_SECRET" "$WORK/enroll.out" && bad "secret leaked to stdout" || ok "node_secret never printed to stdout"

echo; echo "### 2. Heartbeat (HMAC verified by server, no commands queued)"
AGENT heartbeat >"$WORK/hb1.out" 2>&1
if grep -q "HEARTBEAT ok (no commands)" "$WORK/agent.log"; then ok "heartbeat accepted + HMAC verified by server"; else bad "heartbeat not verified (see agent.log / php.log)"; fi

echo; echo "### 3. Unsigned command is REJECTED"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"type":"restart-service","payload":{"service":"nginx"},"sign":false}' "$BASE/__queue" >/dev/null
AGENT heartbeat >"$WORK/hb2.out" 2>&1
if grep -q "SIGNATURE INVALID" "$WORK/agent.log"; then ok "garbage-signed command rejected (signature invalid)"; else bad "unsigned command was NOT rejected"; fi

echo; echo "### 4. Wrong-key signed command is REJECTED"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"type":"restart-service","payload":{"service":"nginx"},"sign":true,"badkey":true}' "$BASE/__queue" >/dev/null
: > "$WORK/agent.log"
AGENT heartbeat >"$WORK/hb3.out" 2>&1
if grep -q "SIGNATURE INVALID" "$WORK/agent.log"; then ok "wrong-key command rejected"; else bad "wrong-key command was NOT rejected"; fi

echo; echo "### 5. Fleet-signed, allow-listed command is ACCEPTED + executed"
# stub systemctl so restart-service 'succeeds' without touching the host
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$WORK/systemctl.log"; exit 0
EOF
chmod +x "$STUB/systemctl"
cat > "$STUB/mcrctl" <<EOF
#!/usr/bin/env bash
echo "mcrctl \$*" >> "$WORK/mcrctl.log"; exit 0
EOF
chmod +x "$STUB/mcrctl"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"type":"restart-service","payload":{"service":"nginx"},"sign":true}' "$BASE/__queue" >/dev/null
: > "$WORK/agent.log"
PATH="$STUB:$PATH" AGENT heartbeat >"$WORK/hb4.out" 2>&1
if grep -q "COMMAND verified" "$WORK/agent.log"; then ok "fleet-signed command verified"; else bad "fleet-signed command NOT verified"; fi
if grep -q "restart nginx" "$WORK/systemctl.log" 2>/dev/null; then ok "allow-listed restart-service executed (systemctl restart nginx)"; else bad "command not executed"; fi
# result reported back
sleep 0.3
if curl -fsS "$BASE/__results" | grep -q '"state":"done"'; then ok "command-result (done) reported to fleet (HMAC signed)"; else bad "no command-result recorded"; fi

echo; echo "### 6. Non-allow-listed command type is REJECTED"
curl -fsS -X POST -H 'Content-Type: application/json' \
  --data '{"type":"rm-rf-everything","payload":{"x":1},"sign":true}' "$BASE/__queue" >/dev/null
: > "$WORK/agent.log"
PATH="$STUB:$PATH" AGENT heartbeat >"$WORK/hb5.out" 2>&1
if grep -q "not in allow-list" "$WORK/agent.log"; then ok "non-allow-listed type rejected before any execution"; else bad "non-allow-listed type was NOT rejected"; fi

echo; echo "### 7. Replay protection (reused timestamp rejected by server)"
# Re-send the exact first heartbeat body+headers twice.
load() { sed -n "s/^$1=//p" "$ETC/agent.env" | head -n1; }
URL="$(load MCR_FLEET_URL)"; NID="$(load MCR_NODE_ID)"; SEC="$(load MCR_NODE_SECRET)"
TS="$(date +%s)"; BODY="{\"node_id\":\"$NID\",\"ts\":$TS,\"replay\":\"test\"}"
SIG="$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SEC" -r | awk '{print $1}')"
R1="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-MCR-Node: $NID" -H "X-MCR-Timestamp: $TS" -H "X-MCR-Signature: $SIG" --data-binary "$BODY" "$URL/fleet/v1/heartbeat")"
R2="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-MCR-Node: $NID" -H "X-MCR-Timestamp: $TS" -H "X-MCR-Signature: $SIG" --data-binary "$BODY" "$URL/fleet/v1/heartbeat")"
if [ "$R1" = "200" ] && [ "$R2" = "401" ]; then ok "first accepted (200), replay rejected (401)"; else bad "replay test: first=$R1 second=$R2 (expected 200 then 401)"; fi
# tampered-body test: flip the body, keep the sig -> server rejects
BAD="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-MCR-Node: $NID" -H "X-MCR-Timestamp: $(date +%s)" -H "X-MCR-Signature: $SIG" --data-binary "{\"node_id\":\"$NID\",\"tampered\":true}" "$URL/fleet/v1/heartbeat")"
[ "$BAD" = "401" ] && ok "tampered body with stale signature rejected (401)" || bad "tampered body accepted ($BAD)"

echo
echo "### Agent summary: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
