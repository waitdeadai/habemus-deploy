#!/usr/bin/env bash
# Tests for bless-deploy.sh. Asserts the hook is non-blocking (always exit 0),
# detects deploys, classifies prod vs preview, journals, and renders the opt-in
# prayer only when enabled.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/bless-deploy.sh"
TMPJ="$(mktemp)"
pass=0; fail=0

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — the hook degrades to a safe no-op without jq."
fi

# run <json> [env-assignments...] -> sets OUT and CODE
run() {
  local json="$1"; shift
  OUT="$(printf '%s' "$json" | env HABEMUS_DEPLOY_JOURNAL="$TMPJ" "$@" bash "$HOOK" 2>/dev/null)"
  CODE=$?
}
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
no()  { fail=$((fail+1)); echo "  FAIL: $1"; }

J_NONDEPLOY='{"tool_name":"Bash","tool_input":{"command":"npm test"}}'
J_PREVIEW='{"tool_name":"Bash","tool_input":{"command":"npm run deploy"}}'
J_PROD='{"tool_name":"Bash","tool_input":{"command":"vercel --prod"}}'
J_PUSHMAIN='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

echo "== exit code is always 0 (never blocks) =="
for j in "$J_NONDEPLOY" "$J_PREVIEW" "$J_PROD" "$J_PUSHMAIN"; do
  run "$j"; [ "$CODE" = "0" ] && ok "exit 0 for: $(printf '%s' "$j" | jq -r .tool_input.command 2>/dev/null)" || no "exit $CODE (expected 0)"
done

echo "== non-deploy command produces no output =="
run "$J_NONDEPLOY"; [ -z "$OUT" ] && ok "npm test -> silent" || no "npm test produced output: $OUT"

echo "== preview deploy: systemMessage, env=preview, no prayer by default =="
run "$J_PREVIEW"
printf '%s' "$OUT" | jq -e '.systemMessage' >/dev/null 2>&1 && ok "emits systemMessage" || no "no systemMessage"
printf '%s' "$OUT" | jq -r '.systemMessage' 2>/dev/null | grep -q "preview deploy" && ok "classified preview" || no "not classified preview"
printf '%s' "$OUT" | jq -r '.systemMessage' 2>/dev/null | grep -qi "pater\|padre\|our father" && no "prayer leaked while disabled" || ok "no prayer when PRAYER_ENABLED unset"

echo "== prod deploy: env=prod, still no permissionDecision (never auto-approves) =="
run "$J_PROD"
printf '%s' "$OUT" | jq -r '.systemMessage' 2>/dev/null | grep -q "prod deploy" && ok "classified prod (vercel --prod)" || no "not classified prod"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1 && no "emitted permissionDecision (would alter permission flow)" || ok "no permissionDecision (deploy permission flow preserved)"

echo "== git push to main classified prod =="
run "$J_PUSHMAIN"
printf '%s' "$OUT" | jq -r '.systemMessage' 2>/dev/null | grep -q "prod deploy" && ok "git push origin main -> prod" || no "git push not prod"

echo "== opt-in prayer renders only when enabled (Latin) =="
run "$J_PROD" PRAYER_ENABLED=true PRAYER_LANG=la
printf '%s' "$OUT" | jq -r '.systemMessage' 2>/dev/null | grep -q "Pater noster" && ok "Pater Noster rendered on prod when enabled" || no "prayer missing when enabled"

echo "== prayer suppressed on preview even when enabled (prod-only default) =="
run "$J_PREVIEW" PRAYER_ENABLED=true PRAYER_LANG=la
printf '%s' "$OUT" | jq -r '.systemMessage' 2>/dev/null | grep -q "Pater noster" && no "prayer leaked on preview" || ok "preview stays quiet (prod-only)"

echo "== kill switch: HABEMUS_DEPLOY_DISABLE=1 -> total no-op =="
run "$J_PROD" HABEMUS_DEPLOY_DISABLE=1
{ [ -z "$OUT" ] && [ "$CODE" = "0" ]; } && ok "disabled -> exit 0, no output" || no "disabled produced output/exit $CODE"

echo "== silent mode: journal only, no message =="
run "$J_PROD" HABEMUS_DEPLOY_SILENT=1
[ -z "$OUT" ] && ok "silent -> no systemMessage" || no "silent produced output"

echo "== journal was written =="
grep -q "env=prod" "$TMPJ" 2>/dev/null && ok "deploy journal recorded a prod line" || no "journal not written"

rm -f "$TMPJ"
echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = "0" ]
