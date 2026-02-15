#!/usr/bin/env bash
#
# sync-db-full.sh — Full Database Sync (Dev → Prod)
#
# Exports the dev database, imports it into prod, performs URL search-replace,
# and flushes caches. Automatically backs up prod DB before import.
#
# Usage:
#   bash scripts/sync-db-full.sh \
#     --ssh-host=HOST --ssh-user=USER --ssh-pass=PASS \
#     [--dev-url=URL] [--prod-url=URL] \
#     [--dev-app=wp-dev-app] [--dev-db=wp-dev-db] \
#     [--prod-app=wp-prod-app] [--prod-server-path=/home/USER/wordpress-prod] \
#     [--wp-path=/var/www/html/web/wp] \
#     [--dry-run] --confirm
#
set -euo pipefail

# ---------- colors (degrade gracefully) ----------
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    RED=$(tput setaf 1) GREEN=$(tput setaf 2) YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4) BOLD=$(tput bold) RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
fi

# ---------- logging ----------
log()  { echo "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${RESET} $*"; }
warn() { echo "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${RESET} $*" >&2; }
err()  { echo "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${RESET} $*" >&2; }
die()  { err "$@"; exit 1; }

# ---------- defaults ----------
SSH_HOST="${SSH_HOSTNAME:-}"
SSH_USER="${SSH_USERNAME:-}"
SSH_PASS="${SSH_PASSWORD:-}"
DEV_URL=""
PROD_URL=""
DEV_APP="wp-dev-app"
DEV_DB="wp-dev-db"
PROD_APP="wp-prod-app"
PROD_SERVER_PATH=""
WP_PATH="/var/www/html/web/wp"
DB_NAME="wordpress_dev"
DB_USER="wordpress"
DB_PASS="wordpress"
DRY_RUN=false
CONFIRM=false

# ---------- parse arguments ----------
for arg in "$@"; do
    case "$arg" in
        --ssh-host=*)          SSH_HOST="${arg#*=}" ;;
        --ssh-user=*)          SSH_USER="${arg#*=}" ;;
        --ssh-pass=*)          SSH_PASS="${arg#*=}" ;;
        --dev-url=*)           DEV_URL="${arg#*=}" ;;
        --prod-url=*)          PROD_URL="${arg#*=}" ;;
        --dev-app=*)           DEV_APP="${arg#*=}" ;;
        --dev-db=*)            DEV_DB="${arg#*=}" ;;
        --prod-app=*)          PROD_APP="${arg#*=}" ;;
        --prod-server-path=*)  PROD_SERVER_PATH="${arg#*=}" ;;
        --wp-path=*)           WP_PATH="${arg#*=}" ;;
        --db-name=*)           DB_NAME="${arg#*=}" ;;
        --db-user=*)           DB_USER="${arg#*=}" ;;
        --db-pass=*)           DB_PASS="${arg#*=}" ;;
        --dry-run)             DRY_RUN=true ;;
        --confirm)             CONFIRM=true ;;
        --help|-h)             head -20 "$0" | tail -18; exit 0 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ---------- helpers ----------
ssh_cmd() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SSH_HOST}" "$@"
}

ssh_cmd_stdin() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SSH_HOST}" "$@"
}

# ---------- auto-detect dev URL ----------
auto_detect_dev_url() {
    if [[ -n "$DEV_URL" ]]; then return; fi
    log "Auto-detecting dev URL from .env files..."
    # Try to find project .env by looking relative to this script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local search_dirs=(
        "$script_dir/.."
        "$script_dir/../../"
        "/a0/usr/projects/emichi_wordpress_dev"
    )
    for dir in "${search_dirs[@]}"; do
        if [[ -f "$dir/.env" ]]; then
            DEV_URL=$(grep -E '^WP_HOME=' "$dir/.env" | head -1 | cut -d\' -f2 | cut -d'"' -f2)
            if [[ -z "$DEV_URL" ]]; then
                DEV_URL=$(grep -E '^WP_HOME=' "$dir/.env" | head -1 | sed "s/^WP_HOME=//" | tr -d "'\"")
            fi
            if [[ -n "$DEV_URL" ]]; then
                log "  Found dev URL: ${BOLD}${DEV_URL}${RESET}"
                return
            fi
        fi
    done
    # Fallback: ask WP-CLI
    DEV_URL=$(docker exec "$DEV_APP" wp option get home --path="$WP_PATH" --allow-root 2>/dev/null || true)
    if [[ -n "$DEV_URL" ]]; then
        log "  Detected dev URL via WP-CLI: ${BOLD}${DEV_URL}${RESET}"
    fi
}

# ---------- auto-detect prod URL ----------
auto_detect_prod_url() {
    if [[ -n "$PROD_URL" ]]; then return; fi
    log "Auto-detecting prod URL via WP-CLI on prod..."
    PROD_URL=$(ssh_cmd "docker exec $PROD_APP wp option get home --path=$WP_PATH --allow-root 2>/dev/null" || true)
    if [[ -n "$PROD_URL" ]]; then
        log "  Detected prod URL: ${BOLD}${PROD_URL}${RESET}"
    fi
}

# ---------- auto-detect prod server path ----------
auto_detect_prod_path() {
    if [[ -n "$PROD_SERVER_PATH" ]]; then return; fi
    PROD_SERVER_PATH="/home/${SSH_USER}/wordpress-prod"
    log "  Using default prod server path: ${BOLD}${PROD_SERVER_PATH}${RESET}"
}

# ---------- validation ----------
validate() {
    local missing=0
    [[ -z "$SSH_HOST" ]] && { err "--ssh-host is required"; missing=1; }
    [[ -z "$SSH_USER" ]] && { err "--ssh-user is required"; missing=1; }
    [[ -z "$SSH_PASS" ]] && { err "--ssh-pass is required"; missing=1; }
    [[ "$CONFIRM" != true && "$DRY_RUN" != true ]] && { err "--confirm is required (or use --dry-run)"; missing=1; }
    [[ $missing -ne 0 ]] && exit 1

    auto_detect_dev_url
    auto_detect_prod_url
    auto_detect_prod_path

    [[ -z "$DEV_URL" ]]  && die "Could not detect dev URL. Provide --dev-url=..."
    [[ -z "$PROD_URL" ]] && die "Could not detect prod URL. Provide --prod-url=..."

    # Verify SSH connectivity
    log "Verifying SSH connectivity..."
    ssh_cmd "echo ok" &>/dev/null || die "Cannot connect to ${SSH_USER}@${SSH_HOST} via SSH"
    log "  SSH connection: ${GREEN}OK${RESET}"

    # Verify dev containers
    log "Verifying dev containers..."
    docker exec "$DEV_DB" echo ok &>/dev/null || die "Dev DB container '$DEV_DB' is not running"
    docker exec "$DEV_APP" echo ok &>/dev/null || die "Dev App container '$DEV_APP' is not running"
    log "  Dev containers: ${GREEN}OK${RESET}"

    # Verify prod container
    log "Verifying prod container..."
    ssh_cmd "docker exec $PROD_APP echo ok" &>/dev/null || die "Prod App container '$PROD_APP' is not reachable"
    log "  Prod container: ${GREEN}OK${RESET}"
}

# ---------- export dev DB ----------
export_dev_db() {
    log "Exporting dev database '${DB_NAME}'..."
    local dump_file="/tmp/sync-dev-db-$(date +%Y%m%d-%H%M%S).sql"
    docker exec "$DEV_DB" mariadb-dump \
        -u"$DB_USER" -p"$DB_PASS" \
        --single-transaction --quick --routines --triggers \
        "$DB_NAME" > "$dump_file"
    local size
    size=$(du -h "$dump_file" | cut -f1)
    log "  Exported ${BOLD}${size}${RESET} to ${dump_file}"
    echo "$dump_file"
}

# ---------- backup prod DB ----------
backup_prod_db() {
    log "Backing up prod database before import..."
    local backup_name="prod-backup-$(date +%Y%m%d-%H%M%S).sql"
    ssh_cmd "docker exec $PROD_APP wp db export /tmp/${backup_name} --path=$WP_PATH --allow-root 2>&1"
    log "  Prod backup saved as: ${BOLD}/tmp/${backup_name}${RESET} (inside prod container)"
    # Also copy to prod host filesystem for safety
    ssh_cmd "docker cp ${PROD_APP}:/tmp/${backup_name} /tmp/${backup_name} 2>/dev/null" || true
    log "  Backup also copied to prod host: /tmp/${backup_name}"
}

# ---------- import to prod ----------
import_to_prod() {
    local dump_file="$1"
    log "Transferring dump to prod host..."
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no \
        "$dump_file" "${SSH_USER}@${SSH_HOST}:/tmp/sync-import.sql"
    log "  Transfer complete."

    log "Copying dump into prod container..."
    ssh_cmd "docker cp /tmp/sync-import.sql ${PROD_APP}:/tmp/sync-import.sql"

    log "Importing database on prod..."
    ssh_cmd "docker exec $PROD_APP wp db import /tmp/sync-import.sql --path=$WP_PATH --allow-root 2>&1"
    log "  ${GREEN}Import complete.${RESET}"

    # Cleanup remote temp files
    ssh_cmd "rm -f /tmp/sync-import.sql" || true
    ssh_cmd "docker exec $PROD_APP rm -f /tmp/sync-import.sql" || true
}

# ---------- search-replace ----------
do_search_replace() {
    log "Running search-replace: ${BOLD}${DEV_URL}${RESET} → ${BOLD}${PROD_URL}${RESET}"
    local result
    result=$(ssh_cmd "docker exec $PROD_APP wp search-replace \
        '${DEV_URL}' '${PROD_URL}' \
        --all-tables --precise --recurse-objects \
        --path=$WP_PATH --allow-root 2>&1")
    echo "$result"
    log "  ${GREEN}Search-replace complete.${RESET}"
}

# ---------- flush caches ----------
flush_caches() {
    log "Flushing caches on prod..."
    ssh_cmd "docker exec $PROD_APP wp cache flush --path=$WP_PATH --allow-root 2>&1" || true
    ssh_cmd "docker exec $PROD_APP wp rewrite flush --path=$WP_PATH --allow-root 2>&1" || true
    ssh_cmd "docker exec $PROD_APP wp transient delete --all --path=$WP_PATH --allow-root 2>&1" || true
    log "  ${GREEN}Caches flushed.${RESET}"
}

# ---------- cleanup ----------
cleanup() {
    log "Cleaning up temporary files..."
    rm -f /tmp/sync-dev-db-*.sql 2>/dev/null || true
}

# ---------- dry-run display ----------
show_dry_run() {
    echo ""
    echo "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
    echo "${BOLD}${BLUE}  DRY RUN — Full Database Sync (Dev → Prod)${RESET}"
    echo "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
    echo ""
    echo "  ${BOLD}Dev DB container:${RESET}    $DEV_DB"
    echo "  ${BOLD}Dev App container:${RESET}   $DEV_APP"
    echo "  ${BOLD}Dev URL:${RESET}             $DEV_URL"
    echo "  ${BOLD}Prod App container:${RESET}  $PROD_APP"
    echo "  ${BOLD}Prod URL:${RESET}            $PROD_URL"
    echo "  ${BOLD}Prod server path:${RESET}    $PROD_SERVER_PATH"
    echo "  ${BOLD}SSH target:${RESET}          ${SSH_USER}@${SSH_HOST}"
    echo "  ${BOLD}WP path:${RESET}             $WP_PATH"
    echo ""
    echo "  ${BOLD}Steps that would execute:${RESET}"
    echo "    1. Export dev DB via mariadb-dump from '$DEV_DB'"
    echo "    2. Backup prod DB via wp db export on '$PROD_APP'"
    echo "    3. SCP dump to prod host, docker cp into prod container"
    echo "    4. Import dump via wp db import on prod"
    echo "    5. Search-replace: '${DEV_URL}' → '${PROD_URL}'"
    echo "    6. Flush all caches (object, rewrite, transients)"
    echo ""
    echo "  ${YELLOW}No changes were made.${RESET}"
    echo ""
}

# ---------- main ----------
main() {
    echo ""
    echo "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
    echo "${BOLD}${BLUE}  Full Database Sync (Dev → Prod)${RESET}"
    echo "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
    echo ""

    validate

    if [[ "$DRY_RUN" == true ]]; then
        show_dry_run
        exit 0
    fi

    echo ""
    warn "${BOLD}This will OVERWRITE the production database!${RESET}"
    warn "A backup will be created, but please ensure you understand the risks."
    echo ""

    # Step 1: Export dev DB
    local dump_file
    dump_file=$(export_dev_db)

    # Step 2: Backup prod DB
    backup_prod_db

    # Step 3: Import to prod
    import_to_prod "$dump_file"

    # Step 4: Search-replace URLs
    do_search_replace

    # Step 5: Flush caches
    flush_caches

    # Step 6: Cleanup
    cleanup

    echo ""
    log "${GREEN}${BOLD}✓ Full database sync complete!${RESET}"
    log "  Dev (${DEV_URL}) → Prod (${PROD_URL})"
    echo ""
}

main "$@"
