#!/bin/bash
# =============================================================================
# Agent Container Entrypoint v2
# Fix: sync entire ~/.openclaw/ (sessions + workspace) instead of /tmp/workspace/
# =============================================================================
set -eo pipefail

TENANT_ID="${SESSION_ID:-${sessionId:-unknown}}"
S3_BUCKET="${S3_BUCKET:-openclaw-tenants-000000000000}"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
STACK_NAME="${STACK_NAME:-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# OpenClaw's actual data directory (sessions, workspace, config)
OPENCLAW_DIR="$HOME/.openclaw"
WORKSPACE_DIR="$OPENCLAW_DIR/workspace"

echo "[entrypoint] START tenant=${TENANT_ID} bucket=${S3_BUCKET}"
echo "[entrypoint] OPENCLAW_DIR=${OPENCLAW_DIR}"

# Prepare directories
mkdir -p "$OPENCLAW_DIR" "$WORKSPACE_DIR" "$WORKSPACE_DIR/memory"

echo "$TENANT_ID" > /tmp/tenant_id

# =============================================================================
# Step 0.5: Write openclaw.json config
# =============================================================================
sed -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
    -e "s|\${BEDROCK_MODEL_ID}|${BEDROCK_MODEL_ID:-global.amazon.nova-2-lite-v1:0}|g" \
    /app/openclaw.json > "$OPENCLAW_DIR/openclaw.json"
echo "[entrypoint] openclaw.json written"

# =============================================================================
# Step 1: Start server.py IMMEDIATELY
# =============================================================================
# Do NOT set OPENCLAW_WORKSPACE — let OpenClaw use its default ~/.openclaw/workspace/
export OPENCLAW_SKIP_ONBOARDING=1

python /app/server.py &
SERVER_PID=$!
echo "[entrypoint] server.py PID=${SERVER_PID}"

# =============================================================================
# S3 sync helper functions
# =============================================================================
S3_SYNC_EXCLUDE="--exclude node_modules/* --exclude .cache/* --exclude *.lock --exclude .npm/* --exclude openclaw.json --exclude skills/_shared/*"

s3_pull() {
    local tenant="$1"
    local s3_base="s3://${S3_BUCKET}/${tenant}"

    # Pull entire .openclaw/ (workspace + sessions + agents)
    aws s3 sync "${s3_base}/openclaw/" "$OPENCLAW_DIR/" \
        $S3_SYNC_EXCLUDE --quiet 2>/dev/null || true

    # Pull shared skills
    aws s3 sync "s3://${S3_BUCKET}/_shared/skills/" "$WORKSPACE_DIR/skills/_shared/" \
        --quiet 2>/dev/null || true
}

s3_push() {
    local tenant="$1"
    local s3_base="s3://${S3_BUCKET}/${tenant}"

    # Push entire .openclaw/ back to S3
    aws s3 sync "$OPENCLAW_DIR/" "${s3_base}/openclaw/" \
        $S3_SYNC_EXCLUDE --quiet 2>/dev/null || true
}

# =============================================================================
# Step 2: S3 sync in background
# =============================================================================
(
    echo "[bg] Waiting for tenant_id from first request..."
    for i in $(seq 1 60); do
        CURRENT_TENANT=$(cat /tmp/tenant_id 2>/dev/null || echo "unknown")
        if [ "$CURRENT_TENANT" != "unknown" ]; then
            break
        fi
        sleep 2
    done
    CURRENT_TENANT=$(cat /tmp/tenant_id 2>/dev/null || echo "$TENANT_ID")
    echo "[bg] Using tenant_id=${CURRENT_TENANT}"

    # Pull from S3
    echo "[bg] Pulling from S3..."
    s3_pull "$CURRENT_TENANT"

    # Initialize SOUL.md for new tenants
    if [ ! -f "$WORKSPACE_DIR/SOUL.md" ]; then
        ROLE=$(aws ssm get-parameter \
            --name "/openclaw/${STACK_NAME}/tenants/${CURRENT_TENANT}/soul-template" \
            --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || echo "default")
        aws s3 cp "s3://${S3_BUCKET}/_shared/templates/${ROLE}.md" "$WORKSPACE_DIR/SOUL.md" \
            --quiet 2>/dev/null || echo "You are a helpful AI assistant." > "$WORKSPACE_DIR/SOUL.md"
    fi

    # Clean up stale .lock files after restore
    find "$OPENCLAW_DIR" -name "*.lock" -delete 2>/dev/null || true

    echo "[bg] Workspace ready"
    echo "WORKSPACE_READY" > /tmp/workspace_status

    # Periodic sync back to S3
    while true; do
        sleep "$SYNC_INTERVAL"
        CURRENT_TENANT=$(cat /tmp/tenant_id 2>/dev/null || echo "$TENANT_ID")
        if [ "$CURRENT_TENANT" != "unknown" ]; then
            s3_push "$CURRENT_TENANT"
        fi
    done
) &
BG_PID=$!
echo "[entrypoint] Background sync PID=${BG_PID}"

# =============================================================================
# Step 3: Graceful shutdown — final S3 push
# =============================================================================
cleanup() {
    echo "[entrypoint] SIGTERM — flushing to S3"
    kill "$BG_PID" 2>/dev/null || true
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    CURRENT_TENANT=$(cat /tmp/tenant_id 2>/dev/null || echo "$TENANT_ID")
    if [ "$CURRENT_TENANT" != "unknown" ]; then
        s3_push "$CURRENT_TENANT"
    fi
    echo "[entrypoint] Done"
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "[entrypoint] Waiting..."
wait "$SERVER_PID" || true
