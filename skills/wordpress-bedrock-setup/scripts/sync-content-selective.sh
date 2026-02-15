#!/usr/bin/env bash
#
# sync-content-selective.sh — Selective Content Sync (Dev → Prod)
#
# Exports specific posts/pages by ID from dev, replaces URLs,
# and updates/creates them on prod.
#
# Usage:
#   bash scripts/sync-content-selective.sh \
#     --ids=442,524 \
#     --ssh-host=HOST --ssh-user=USER --ssh-pass=PASS \
#     [--dev-url=URL] [--prod-url=URL] \
#     [--dev-app=wp-dev-app] [--prod-app=wp-prod-app] \
#     [--wp-path=/var/www/html/web/wp] \
#     [--dry-run]
#
set -euo pipefail

# ---------- colors ----------
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    RED=$(tput setaf 1) GREEN=$(tput setaf 2) YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4) CYAN=$(tput setaf 6) BOLD=$(tput bold) RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" RESET=""
fi

# ---------- logging ----------
log()  { echo "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${RESET} $*"; }
warn() { echo "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${RESET} $*" >&2; }
err()  { echo "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${RESET} $*" >&2; }
die()  { err "$@"; exit 1; }

# ---------- defaults ----------
IDS=""
SSH_HOST="${SSH_HOSTNAME:-}"
SSH_USER="${SSH_USERNAME:-}"
SSH_PASS="${SSH_PASSWORD:-}"
DEV_URL=""
PROD_URL=""
DEV_APP="wp-dev-app"
PROD_APP="wp-prod-app"
WP_PATH="/var/www/html/web/wp"
DRY_RUN=false

# ---------- parse arguments ----------
for arg in "$@"; do
    case "$arg" in
        --ids=*)       IDS="${arg#*=}" ;;
        --ssh-host=*)  SSH_HOST="${arg#*=}" ;;
        --ssh-user=*)  SSH_USER="${arg#*=}" ;;
        --ssh-pass=*)  SSH_PASS="${arg#*=}" ;;
        --dev-url=*)   DEV_URL="${arg#*=}" ;;
        --prod-url=*)  PROD_URL="${arg#*=}" ;;
        --dev-app=*)   DEV_APP="${arg#*=}" ;;
        --prod-app=*)  PROD_APP="${arg#*=}" ;;
        --wp-path=*)   WP_PATH="${arg#*=}" ;;
        --dry-run)     DRY_RUN=true ;;
        --help|-h)     head -16 "$0" | tail -14; exit 0 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ---------- helpers ----------
ssh_cmd() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SSH_HOST}" "$@"
}

dev_wp() {
    docker exec "$DEV_APP" wp "$@" --path="$WP_PATH" --allow-root 2>/dev/null
}

prod_wp() {
    ssh_cmd "docker exec $PROD_APP wp $* --path=$WP_PATH --allow-root 2>/dev/null"
}

# ---------- auto-detect dev URL ----------
auto_detect_dev_url() {
    if [[ -n "$DEV_URL" ]]; then return; fi
    log "Auto-detecting dev URL..."
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local search_dirs=(
        "$script_dir/.."
        "$script_dir/../../"
        "/a0/usr/projects/emichi_wordpress_dev"
    )
    for dir in "${search_dirs[@]}"; do
        if [[ -f "$dir/.env" ]]; then
            DEV_URL=$(grep -E '^WP_HOME=' "$dir/.env" | head -1 | sed "s/^WP_HOME=//" | tr -d "'\"")
            if [[ -n "$DEV_URL" ]]; then
                log "  Found dev URL: ${BOLD}${DEV_URL}${RESET}"
                return
            fi
        fi
    done
    DEV_URL=$(dev_wp option get home || true)
    [[ -n "$DEV_URL" ]] && log "  Detected dev URL via WP-CLI: ${BOLD}${DEV_URL}${RESET}"
}

# ---------- auto-detect prod URL ----------
auto_detect_prod_url() {
    if [[ -n "$PROD_URL" ]]; then return; fi
    log "Auto-detecting prod URL..."
    PROD_URL=$(prod_wp "option get home" || true)
    [[ -n "$PROD_URL" ]] && log "  Detected prod URL: ${BOLD}${PROD_URL}${RESET}"
}

# ---------- validation ----------
validate() {
    local missing=0
    [[ -z "$IDS" ]]      && { err "--ids is required (comma-separated post IDs)"; missing=1; }
    [[ -z "$SSH_HOST" ]]  && { err "--ssh-host is required"; missing=1; }
    [[ -z "$SSH_USER" ]]  && { err "--ssh-user is required"; missing=1; }
    [[ -z "$SSH_PASS" ]]  && { err "--ssh-pass is required"; missing=1; }
    [[ $missing -ne 0 ]] && exit 1

    auto_detect_dev_url
    auto_detect_prod_url

    [[ -z "$DEV_URL" ]]  && die "Could not detect dev URL. Provide --dev-url=..."
    [[ -z "$PROD_URL" ]] && die "Could not detect prod URL. Provide --prod-url=..."

    # Verify connectivity
    log "Verifying connectivity..."
    docker exec "$DEV_APP" echo ok &>/dev/null || die "Dev container '$DEV_APP' not running"
    ssh_cmd "docker exec $PROD_APP echo ok" &>/dev/null || die "Prod container '$PROD_APP' not reachable"
    log "  Connectivity: ${GREEN}OK${RESET}"
}

# ---------- export post from dev ----------
export_post() {
    local id="$1"
    local field="$2"
    dev_wp post get "$id" --field="$field"
}

# ---------- check if post exists on prod ----------
post_exists_on_prod() {
    local id="$1"
    prod_wp "post get $id --field=ID" 2>/dev/null && return 0 || return 1
}

# ---------- sync single post ----------
sync_post() {
    local id="$1"
    local synced=0
    local created=0

    echo ""
    log "${BOLD}${CYAN}── Post ID: ${id} ──${RESET}"

    # Export fields from dev
    local title status post_type slug content
    title=$(export_post "$id" "post_title" || true)
    status=$(export_post "$id" "post_status" || true)
    post_type=$(export_post "$id" "post_type" || true)
    slug=$(export_post "$id" "post_name" || true)
    content=$(export_post "$id" "post_content" || true)

    if [[ -z "$title" && -z "$content" ]]; then
        err "  Post ID $id not found on dev. Skipping."
        return 1
    fi

    log "  Title:  ${BOLD}${title}${RESET}"
    log "  Type:   ${post_type}"
    log "  Status: ${status}"
    log "  Slug:   ${slug}"
    log "  Content length: ${#content} chars"

    # URL replacement in content
    if [[ -n "$content" && "$DEV_URL" != "$PROD_URL" ]]; then
        local original_content="$content"
        content="${content//$DEV_URL/$PROD_URL}"
        if [[ "$content" != "$original_content" ]]; then
            log "  ${GREEN}URL replacements applied in content${RESET}"
        else
            log "  No URL replacements needed in content"
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "  ${YELLOW}[DRY RUN]${RESET} Would sync this post to prod"
        if post_exists_on_prod "$id"; then
            log "  ${YELLOW}[DRY RUN]${RESET} Post exists on prod → would UPDATE"
        else
            log "  ${YELLOW}[DRY RUN]${RESET} Post not found on prod → would CREATE"
        fi
        return 0
    fi

    # Write content to temp file to avoid shell escaping issues
    local tmp_content="/tmp/sync-post-${id}-content.txt"
    echo "$content" > "$tmp_content"

    if post_exists_on_prod "$id"; then
        log "  Post exists on prod → ${BOLD}UPDATING${RESET}"

        # Transfer content file to prod
        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no \
            "$tmp_content" "${SSH_USER}@${SSH_HOST}:/tmp/sync-post-${id}-content.txt"
        ssh_cmd "docker cp /tmp/sync-post-${id}-content.txt ${PROD_APP}:/tmp/sync-post-${id}-content.txt"

        # Update post fields
        ssh_cmd "docker exec $PROD_APP wp post update $id \
            --post_title='$(echo "$title" | sed "s/'/'\\''/g")' \
            --post_status='$status' \
            --post_name='$slug' \
            --post_content="'"'$(cat /tmp/sync-post-'"$id"'-content.txt)'"'" \
            --path=$WP_PATH --allow-root 2>&1" || {
            # Fallback: update via content file piped to stdin
            ssh_cmd "docker exec -i $PROD_APP wp post update $id \
                --post_title='$(echo "$title" | sed "s/'/'\\''/g")' \
                --post_status='$status' \
                --post_name='$slug' \
                --path=$WP_PATH --allow-root < /dev/null 2>&1"
            # Update content separately
            ssh_cmd "cat /tmp/sync-post-${id}-content.txt | docker exec -i $PROD_APP wp post update $id \
                --post_content \
                --path=$WP_PATH --allow-root 2>&1" || true
        }

        # Cleanup remote temp
        ssh_cmd "rm -f /tmp/sync-post-${id}-content.txt" || true
        ssh_cmd "docker exec $PROD_APP rm -f /tmp/sync-post-${id}-content.txt" || true

        log "  ${GREEN}✓ Updated post ${id} on prod${RESET}"
        synced=1
    else
        log "  Post not found on prod → ${BOLD}CREATING${RESET}"

        # Transfer content file to prod
        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no \
            "$tmp_content" "${SSH_USER}@${SSH_HOST}:/tmp/sync-post-${id}-content.txt"
        ssh_cmd "docker cp /tmp/sync-post-${id}-content.txt ${PROD_APP}:/tmp/sync-post-${id}-content.txt"

        local new_id
        new_id=$(ssh_cmd "docker exec $PROD_APP wp post create \
            --post_title='$(echo "$title" | sed "s/'/'\\''/g")' \
            --post_status='$status' \
            --post_type='$post_type' \
            --post_name='$slug' \
            --porcelain \
            --path=$WP_PATH --allow-root 2>/dev/null" || echo "")

        if [[ -n "$new_id" ]]; then
            log "  ${GREEN}✓ Created post on prod with ID: ${new_id}${RESET}"
            # Note: new ID may differ from dev ID
            if [[ "$new_id" != "$id" ]]; then
                warn "  New prod ID ($new_id) differs from dev ID ($id)"
            fi
        else
            err "  Failed to create post on prod"
        fi

        # Cleanup
        ssh_cmd "rm -f /tmp/sync-post-${id}-content.txt" || true
        ssh_cmd "docker exec $PROD_APP rm -f /tmp/sync-post-${id}-content.txt" || true

        created=1
    fi

    # Cleanup local temp
    rm -f "$tmp_content" 2>/dev/null || true
}

# ---------- main ----------
main() {
    echo ""
    echo "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
    echo "${BOLD}${BLUE}  Selective Content Sync (Dev → Prod)${RESET}"
    echo "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
    echo ""

    validate

    # Parse IDs
    IFS=',' read -ra ID_ARRAY <<< "$IDS"
    local total=${#ID_ARRAY[@]}
    log "Syncing ${BOLD}${total}${RESET} post(s): ${IDS}"
    log "URL replacement: ${BOLD}${DEV_URL}${RESET} → ${BOLD}${PROD_URL}${RESET}"

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        warn "${BOLD}DRY RUN MODE — no changes will be made${RESET}"
    fi

    local success=0
    local failed=0

    for id in "${ID_ARRAY[@]}"; do
        id=$(echo "$id" | tr -d ' ')  # trim whitespace
        if [[ -z "$id" ]]; then continue; fi

        if sync_post "$id"; then
            ((success++)) || true
        else
            ((failed++)) || true
        fi
    done

    echo ""
    echo "${BOLD}${BLUE}─── Summary ───${RESET}"
    log "  Total:     ${total}"
    log "  Processed: ${GREEN}${success}${RESET}"
    log "  Failed:    ${RED}${failed}${RESET}"

    if [[ "$DRY_RUN" == true ]]; then
        log "  ${YELLOW}Dry run — no changes were made${RESET}"
    fi
    echo ""
}

main "$@"
