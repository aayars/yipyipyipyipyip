#!/usr/bin/env bash
set -euo pipefail

# EHSRE Autonomous Rounds
# Runs every 90 minutes via cron. Gathers instance state, invokes Claude
# with the prompt template, and logs telemetry.
#
# Dependencies: claude CLI, jq, curl, docker compose

YIPYIP_DIR="/root/yipyip"
PROMPT_FILE="${YIPYIP_DIR}/ehsre-prompt.md"
LOCK_FILE="/var/lib/ehsre/claude.lock"
LOG_DIR="/var/log/ehsre"
TELEMETRY_FILE="${LOG_DIR}/telemetry.jsonl"
BASE_URL="https://yip.yip.yip.yip.yip.computer"

# Secrets are stored in env files, never hardcoded
EHSRE_ENV="/home/ehsre/.env.ehsre"
ADMIN_TOKEN_FILE="/root/yipyip/.env.ehsre-admin"

# Ensure PATH includes Claude CLI
export PATH="$HOME/.local/bin:$PATH"

# Load admin token from env file
if [ ! -f "$ADMIN_TOKEN_FILE" ]; then
    echo "FATAL: Admin token file not found: $ADMIN_TOKEN_FILE" >&2
    exit 1
fi
ADMIN_TOKEN=$(grep '^ADMIN_TOKEN=' "$ADMIN_TOKEN_FILE" | cut -d= -f2-)
if [ -z "$ADMIN_TOKEN" ]; then
    echo "FATAL: ADMIN_TOKEN not set in $ADMIN_TOKEN_FILE" >&2
    exit 1
fi

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

cleanup() {
    rm -f "$LOCK_FILE"
    # Keep last run output for debugging
    if [ -n "${claude_out:-}" ] && [ -f "$claude_out" ]; then
        cp "$claude_out" "${LOG_DIR}/last-run-output.json" 2>/dev/null || true
        rm -f "$claude_out"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Lock file management
# ---------------------------------------------------------------------------
if [ -f "$LOCK_FILE" ]; then
    # stat -c is GNU coreutils (Linux). Get file modification time in epoch.
    lock_mtime=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
    lock_age=$(( $(date +%s) - lock_mtime ))
    if [ "$lock_age" -lt 600 ]; then
        log "Claude already running (lock age ${lock_age}s), skipping"
        # Disable cleanup trap so we don't remove someone else's lock
        trap - EXIT
        exit 0
    else
        log "Stale lock file (${lock_age}s old), removing"
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"

# ---------------------------------------------------------------------------
# Gather instance state
# ---------------------------------------------------------------------------
log "Gathering instance state..."

# Helper: Mastodon API GET with auth and fallback
masto_get() {
    curl -sf -H "Authorization: Bearer ${ADMIN_TOKEN}" "$1" 2>/dev/null || echo "[]"
}

# ---------------------------------------------------------------------------
# Input sanitization — all user-generated content is untrusted.
# Strip API responses to essential fields only and truncate text.
# This prevents prompt injection via crafted posts/applications/DMs.
# ---------------------------------------------------------------------------
sanitize_apps() {
    jq '[.[] | {
        id: .id,
        username: (.username // "" | .[:64]),
        created_at: .created_at,
        email: (.email // "" | .[:128]),
        ip: .ip,
        invite_request: ((.invite_request // "") | .[:500])
    }]' 2>/dev/null <<< "$1" || echo "[]"
}

sanitize_timeline() {
    jq '[.[] | {
        id: .id,
        created_at: .created_at,
        account_id: .account.id,
        acct: (.account.acct // "" | .[:64]),
        display_name: (.account.display_name // "" | .[:64]),
        content: ((.content // "") | .[:1000]),
        visibility: .visibility,
        replies_count: .replies_count,
        reblogs_count: .reblogs_count,
        favourites_count: .favourites_count
    }]' 2>/dev/null <<< "$1" || echo "[]"
}

sanitize_notifications() {
    jq '[.[] | {
        id: .id,
        type: .type,
        created_at: .created_at,
        account_acct: (.account.acct // "" | .[:64]),
        account_id: .account.id,
        status_id: .status.id,
        status_content: ((.status.content // "") | .[:1000])
    }]' 2>/dev/null <<< "$1" || echo "[]"
}

sanitize_conversations() {
    jq '[.[] | {
        id: .id,
        unread: .unread,
        last_status_id: .last_status.id,
        last_status_content: ((.last_status.content // "") | .[:1000]),
        last_status_created_at: .last_status.created_at,
        accounts: [.accounts[] | {id: .id, acct: (.acct // "" | .[:64])}]
    }]' 2>/dev/null <<< "$1" || echo "[]"
}

sanitize_follow_requests() {
    jq '[.[] | {
        id: .id,
        acct: (.acct // "" | .[:64]),
        display_name: (.display_name // "" | .[:64]),
        note: ((.note // "") | .[:500])
    }]' 2>/dev/null <<< "$1" || echo "[]"
}

sanitize_reports() {
    jq '[.[] | {
        id: .id,
        action_taken: .action_taken,
        category: .category,
        comment: ((.comment // "") | .[:500]),
        created_at: .created_at,
        target_account_id: .target_account.id,
        target_account_acct: (.target_account.acct // "" | .[:64]),
        status_ids: .status_ids
    }]' 2>/dev/null <<< "$1" || echo "[]"
}

sanitize_own_posts() {
    jq '[.[] | {
        id: .id,
        created_at: .created_at,
        content: ((.content // "") | .[:500])
    }]' 2>/dev/null <<< "$1" || echo "[]"
}

# Container health
container_status=$(cd "$YIPYIP_DIR" && docker compose ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || echo "ERROR: could not get container status")

# Disk usage
disk_usage=$(df -h / | tail -1 | awk '{print $5}')

# Pending applications (sanitized)
raw_apps=$(masto_get "${BASE_URL}/api/v1/admin/accounts?status=pending&limit=20")
pending_apps=$(sanitize_apps "$raw_apps")

# Recent local timeline (sanitized)
raw_timeline=$(masto_get "${BASE_URL}/api/v1/timelines/public?local=true&limit=40")
recent_timeline=$(sanitize_timeline "$raw_timeline")

# Notifications (sanitized)
raw_notifs=$(masto_get "${BASE_URL}/api/v1/notifications?limit=20")
recent_notifs=$(sanitize_notifications "$raw_notifs")

# DMs / Conversations (sanitized)
raw_convos=$(masto_get "${BASE_URL}/api/v1/conversations?limit=20")
conversations=$(sanitize_conversations "$raw_convos")

# Follow requests (sanitized)
raw_follows=$(masto_get "${BASE_URL}/api/v1/follow_requests")
follow_requests=$(sanitize_follow_requests "$raw_follows")

# Open reports (sanitized)
raw_reports=$(masto_get "${BASE_URL}/api/v1/admin/reports?resolved=false")
open_reports=$(sanitize_reports "$raw_reports")

# Own recent posts (sanitized)
own_account_id=$(curl -sf -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${BASE_URL}/api/v1/accounts/verify_credentials" 2>/dev/null \
    | jq -r '.id // empty' 2>/dev/null || echo "")

own_recent_posts="[]"
if [ -n "$own_account_id" ]; then
    raw_own=$(masto_get "${BASE_URL}/api/v1/accounts/${own_account_id}/statuses?limit=10")
    own_recent_posts=$(sanitize_own_posts "$raw_own")
fi

# Sidekiq status (last 10 lines)
sidekiq_status=$(cd "$YIPYIP_DIR" && docker compose logs --tail=10 sidekiq 2>/dev/null || echo "no sidekiq logs")

# Latest backup (*.dump files from bin/backup)
latest_backup=$(ls -t "${YIPYIP_DIR}/data/backups/"*.dump 2>/dev/null | head -1 || echo "")
if [ -n "$latest_backup" ]; then
    backup_mtime=$(stat -c %Y "$latest_backup" 2>/dev/null || echo 0)
    backup_age=$(( $(date +%s) - backup_mtime ))
    backup_info="${latest_backup} ($(( backup_age / 3600 ))h ago)"
else
    backup_info="NO BACKUPS FOUND"
fi

# Last vacuum timestamp
last_vacuum="never"
if [ -f "${LOG_DIR}/last-vacuum" ]; then
    last_vacuum=$(cat "${LOG_DIR}/last-vacuum")
fi

# Persistent memory from previous rounds
MEMORY_FILE="/var/lib/ehsre/memory.md"
ehsre_memory=""
if [ -f "$MEMORY_FILE" ]; then
    ehsre_memory=$(head -c 8000 "$MEMORY_FILE")
fi

# ---------------------------------------------------------------------------
# Build instance state block
# ---------------------------------------------------------------------------
instance_state=$(cat <<STATE
### Container Status
\`\`\`
${container_status}
\`\`\`

### Disk Usage
${disk_usage} used

### Pending Applications ($(echo "$pending_apps" | jq 'length' 2>/dev/null || echo 0))
\`\`\`json
${pending_apps}
\`\`\`

### Recent Timeline (last 40 posts)
\`\`\`json
${recent_timeline}
\`\`\`

### Recent Notifications (last 20)
\`\`\`json
${recent_notifs}
\`\`\`

### DMs / Conversations (last 20)
\`\`\`json
${conversations}
\`\`\`

### Follow Requests
\`\`\`json
${follow_requests}
\`\`\`

### Open Reports
\`\`\`json
${open_reports}
\`\`\`

### Your Recent Posts (last 10 — avoid repeating yourself)
\`\`\`json
${own_recent_posts}
\`\`\`

### Sidekiq Status
\`\`\`
${sidekiq_status}
\`\`\`

### Backup Status
${backup_info}

### Last DB Vacuum
${last_vacuum}

### Current Time
$(date -u +%Y-%m-%dT%H:%M:%SZ)

### Your Memory (from previous rounds)
${ehsre_memory:-No memory file yet. Start writing to /var/lib/ehsre/memory.md.}
STATE
)

# ---------------------------------------------------------------------------
# Build prompt (substitute template variable)
# ---------------------------------------------------------------------------
prompt=$(cat "$PROMPT_FILE")
prompt="${prompt//\{\{INSTANCE_STATE\}\}/$instance_state}"

# ---------------------------------------------------------------------------
# Invoke Claude (as ehsre user — bypassPermissions requires non-root)
# ---------------------------------------------------------------------------
log "Starting EHSRE rounds..."
claude_out=$(mktemp)
chmod 666 "$claude_out"
start_ms=$(date +%s%3N)

# Write prompt to a shared temp file (too large for command-line args)
prompt_tmp=$(mktemp /tmp/ehsre-prompt.XXXXXX)
printf '%s' "$prompt" > "$prompt_tmp"
chmod 644 "$prompt_tmp"

# Run Claude as the ehsre user (bypassPermissions blocked for root)
sudo -u ehsre \
    env "PATH=/home/ehsre/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        "ANTHROPIC_API_KEY=$(grep ANTHROPIC_API_KEY ${EHSRE_ENV} | cut -d= -f2-)" \
        "ADMIN_TOKEN=${ADMIN_TOKEN}" \
    claude -p "$(cat "$prompt_tmp")" \
        --allowedTools "Bash(description:Run commands on the yipyip Mastodon server. Use curl with ADMIN_TOKEN env var for API calls. Use docker compose from /root/yipyip for maintenance. NEVER output credential values.)" \
        --permission-mode bypassPermissions \
        --output-format json \
    > "$claude_out" 2>/dev/null

rm -f "$prompt_tmp"

end_ms=$(date +%s%3N)
duration_ms=$(( end_ms - start_ms ))

log "Rounds complete (${duration_ms}ms)"

# ---------------------------------------------------------------------------
# Telemetry logging
# ---------------------------------------------------------------------------
if [ -f "$claude_out" ] && [ -s "$claude_out" ]; then
    telemetry=$(jq -nc \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson duration "$duration_ms" \
        --argjson data "$(cat "$claude_out")" \
        '{
            ts: $ts,
            source: "rounds",
            cost_usd: ($data.cost_usd // 0),
            input_tokens: ($data.usage.input_tokens // 0),
            cache_read_input_tokens: ($data.usage.cache_read_input_tokens // 0),
            output_tokens: ($data.usage.output_tokens // 0),
            duration_ms: $duration,
            num_turns: ($data.num_turns // 0)
        }' 2>/dev/null || echo '{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","source":"rounds","error":"parse_failed"}')

    echo "$telemetry" >> "$TELEMETRY_FILE"

    # Human-readable summary to stdout (goes to rounds.log via cron redirect)
    cost=$(echo "$telemetry" | jq -r '.cost_usd // 0' 2>/dev/null || echo "?")
    in_tok=$(echo "$telemetry" | jq -r '.input_tokens // 0' 2>/dev/null || echo "?")
    cache_tok=$(echo "$telemetry" | jq -r '.cache_read_input_tokens // 0' 2>/dev/null || echo "?")
    out_tok=$(echo "$telemetry" | jq -r '.output_tokens // 0' 2>/dev/null || echo "?")
    turns=$(echo "$telemetry" | jq -r '.num_turns // 0' 2>/dev/null || echo "?")
    log "Telemetry: \$${cost} | ${in_tok} in (${cache_tok} cached) + ${out_tok} out | ${turns} turns | ${duration_ms}ms"
else
    log "WARNING: Claude produced no output"
    echo '{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","source":"rounds","error":"no_output","duration_ms":'"$duration_ms"'}' >> "$TELEMETRY_FILE"
fi
