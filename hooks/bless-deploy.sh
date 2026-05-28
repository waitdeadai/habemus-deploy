#!/usr/bin/env bash
# Habemus Deploy — Rome Call Blessing Hook
# A Claude Code PreToolUse(Bash) hook that, when the agent is about to run a
# deploy command:
#   1. appends a structured line to a deploy journal,
#   2. surfaces whether this is a prod or preview deploy,
#   3. (opt-in) prays a Padre Nuestro over production releases.
#
# It is NON-BLOCKING BY CONSTRUCTION: it only ever exits 0 and, at most, emits
# a {"systemMessage": ...} object. It NEVER blocks, denies, asks, gates, delays,
# or auto-approves a deploy. Every failure path is `exit 0` with no output.
#
# Independent, unofficial tribute to the Vatican's AI-ethics work (the Rome Call
# for AI Ethics). NOT affiliated with or endorsed by the Holy See, the
# Pontifical Academy for Life, the RenAIssance Foundation, or Anthropic.
# See the NOTICE file.
#
# Design note: we deliberately do NOT emit permissionDecision:"allow", because
# that would skip your normal permission prompt and auto-run the deploy. We emit
# only systemMessage, so your usual deploy confirmation flow stays intact.

set -u

# --- 0. Global kill switch -------------------------------------------------
[ "${HABEMUS_DEPLOY_DISABLE:-}" = "1" ] && exit 0

# --- 1. Read the PreToolUse event from stdin -------------------------------
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

# jq parses/encodes JSON safely. If it is missing, become a no-op rather than
# risk interfering with the deploy.
command -v jq >/dev/null 2>&1 || exit 0

COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -z "$COMMAND" ] && exit 0

# --- 2. Detect a deploy command -------------------------------------------
DEPLOY_RE='vercel[[:space:]]+(deploy|--prod|--production)|git[[:space:]]+push|docker[[:space:]]+(build|compose[[:space:]]+up|push)|kubectl[[:space:]]+apply|helm[[:space:]]+(install|upgrade)|fly[[:space:]]+deploy|wrangler[[:space:]]+deploy|gcloud[[:space:]]+(run[[:space:]]+deploy|app[[:space:]]+deploy)|aws[[:space:]]+(deploy|s3[[:space:]]+sync)|npm[[:space:]]+run[[:space:]]+deploy|pnpm[[:space:]]+(run[[:space:]]+)?deploy|yarn[[:space:]]+deploy|cap[[:space:]]+deploy|gh[[:space:]]+release[[:space:]]+create|terraform[[:space:]]+apply|serverless[[:space:]]+deploy|sls[[:space:]]+deploy'
# `-e` marks the pattern explicitly so a leading "-" is never read as an option.
printf '%s' "$COMMAND" | grep -Eq -e "$DEPLOY_RE" 2>/dev/null || exit 0

# --- 3. Classify prod vs preview ------------------------------------------
ENV="preview"
PROD_RE='--prod|--production|git[[:space:]]+push([[:space:]].*)?(main|master|production|release)|kubectl[[:space:]]+apply|terraform[[:space:]]+apply|helm[[:space:]]+(install|upgrade)|gh[[:space:]]+release[[:space:]]+create|gcloud[[:space:]]+(run|app)[[:space:]]+deploy|fly[[:space:]]+deploy'
# `-e` is essential here: PROD_RE starts with "--prod", which grep would
# otherwise parse as an option (end-of-options), silently never matching.
printf '%s' "$COMMAND" | grep -Eq -e "$PROD_RE" 2>/dev/null && ENV="prod"

# --- 4. Append a structured deploy-journal line (errors swallowed) ---------
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo nogit)"
JOURNAL="${HABEMUS_DEPLOY_JOURNAL:-${CLAUDE_PROJECT_DIR:-.}/.claude/deploy-journal.log}"
if [ "$JOURNAL" != "/dev/null" ]; then
  {
    mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null
    printf '%s\tenv=%s\tsha=%s\tbranch=%s\tcwd=%s\tcmd=%s\n' \
      "$TS" "$ENV" "$SHA" "$BRANCH" "$(pwd 2>/dev/null)" "$COMMAND" >> "$JOURNAL" 2>/dev/null
  } || true
fi

# --- 5. Silent (journal-only) mode ----------------------------------------
[ "${HABEMUS_DEPLOY_SILENT:-}" = "1" ] && exit 0

# --- 6. Compose the (non-blocking) user-visible message -------------------
MSG="Habemus Deploy — ${ENV} deploy detected [${SHA}@${BRANCH} · ${TS}]"

# Optional gentle Friday / late-night checkpoint (never blocks).
if [ "${HABEMUS_DEPLOY_FRIDAY_NUDGE:-true}" = "true" ]; then
  DOW="$(date +%u 2>/dev/null || echo 0)"   # 5=Fri 6=Sat 7=Sun
  HOUR="$(date +%H 2>/dev/null || echo 12)"
  if [ "$DOW" = "5" ] && [ "$ENV" = "prod" ]; then
    MSG="${MSG}
A production deploy on a Friday — worth a breath. Are you sure?"
  elif { [ "$HOUR" -ge 22 ] || [ "$HOUR" -lt 6 ]; } 2>/dev/null && [ "$ENV" = "prod" ]; then
    MSG="${MSG}
A late-night production deploy — worth a breath. Are you sure?"
  fi
fi

# Opt-in prayer. Disabled by default. By default rendered only for prod deploys
# (set HABEMUS_DEPLOY_PROD_ONLY=false to bless previews too).
if [ "${PRAYER_ENABLED:-false}" = "true" ]; then
  PROD_ONLY="${HABEMUS_DEPLOY_PROD_ONLY:-true}"
  if [ "$PROD_ONLY" != "true" ] || [ "$ENV" = "prod" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
    case "${PRAYER_LANG:-la}" in
      es) PRAYER_FILE="$SCRIPT_DIR/../prayers/padre-nuestro.txt" ;;
      en) PRAYER_FILE="$SCRIPT_DIR/../prayers/our-father.txt" ;;
      *)  PRAYER_FILE="$SCRIPT_DIR/../prayers/pater-noster.txt" ;;
    esac
    # Allow a fully custom prayer/quote file (swap for any text, or none).
    PRAYER_FILE="${HABEMUS_DEPLOY_PRAYER_FILE:-$PRAYER_FILE}"
    if [ -f "$PRAYER_FILE" ]; then
      PRAYER="$(cat "$PRAYER_FILE" 2>/dev/null || true)"
      [ -n "$PRAYER" ] && MSG="${MSG}

${PRAYER}"
    fi
  fi
fi

# --- 7. Emit the non-blocking message and exit cleanly --------------------
# jq -n safely encodes newlines/quotes. No permissionDecision => the normal
# permission flow is preserved (we never auto-approve the deploy).
jq -n --arg msg "$MSG" '{systemMessage:$msg}' 2>/dev/null || true
exit 0
