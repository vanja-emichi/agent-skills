#!/usr/bin/env bash
#
# sync-uploads.sh — Media/Uploads Sync
#
# Syncs upload files between dev and prod via rsync over SSH.
# Default direction: dev → prod.
#
# Usage:
#   bash scripts/sync-uploads.sh \
#     --ssh-host=HOST --ssh-user=USER --ssh-pass=PASS \
#     [--direction=dev-to-prod] [--dry-run] \
#     [--dev-app=wp-dev-app] [--prod-app=wp-prod-app] \
#     [--prod-server-path=/home/USER/wordpress-prod]
#
set -euo pipefail

# ---------- colors ----------
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
DIRECTION="dev-to-prod"
DRY_RUN=false
DEV_APP="wp-dev-app"
PROD_APP="wp-prod-app"
PROD_SERVER_PATH=""
UPLOADS_SUBPATH="web/app/uploads/"

# ---------- parse arguments ----------
for arg in "$@"; do
    case "$arg" in
        --ssh-host=*)          SSH_HOST="${arg#*=}" ;;
        --ssh-user=*)          SSH_USER="${arg#*=}" ;;
        --ssh-pass=*)          SSH_PASS="${arg#*=}" ;;
        --direction=*)         DIRECTION="${arg#*=}" ;;
        --dev-app=*)           DEV_APP="${arg#*=}" ;;
        --prod-app=*)          PROD_APP="${arg#*=}" ;;
        --prod-server-path=*)  PROD_SERVER_PATH="${arg#*=}" ;;
        --uploads-path=*)      UPLOADS_SUBPATH="${arg#*=}" ;;
        --dry-run)             DRY_RUN=true ;;
        --help|-h)             head -15 "$0" | tail -13; exit 0 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ---------- helpers ----------
ssh_cmd() {
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SSH_HOST}" "$@"
}

# ---------- auto-detect paths ----------
auto_detect_dev_uploads() {
    # Resolve dev uploads path by inspecting the dev container bind mount
    # The A0 container can access files directly since dev is on the same Docker host
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local search_dirs=(
        "$script_dir/.."
        "$script_dir/../../"
        "/a0/usr/projects/emichi_wordpress_dev"
    )
    for dir in "${search_dirs[@]}"; do
        local candidate="${dir}/${UPLOADS_SUBPATH}"
        if [[ -d "$candidate" ]]; then
            DEV_UPLOADS_PATH=$(cd "$candidate" && pwd)
            log "  Dev uploads path: ${BOLD}${DEV_UPLOADS_PATH}${RESET}"
            return
        fi
    done
    die "Could not find dev uploads directory. Expected at <project>/${UPLOADS_SUBPATH}"
}

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
    [[ $missing -ne 0 ]] && exit 1

    if [[ "$DIRECTION" != "dev-to-prod" && "$DIRECTION" != "prod-to-dev" ]]; then
        die "--direction must be 'dev-to-prod' or 'prod-to-dev'"
    fi

    auto_detect_dev_uploads
    auto_detect_prod_path

    PROD_UPLOADS_PATH="${PROD_SERVER_PATH}/${UPLOADS_SUBPATH}"

    # Verify SSH
    log "Verifying SSH connectivity..."
    ssh_cmd "echo ok" &>/dev/null || die "Cannot connect to ${SSH_USER}@${SSH_HOST} via SSH"
    log "  SSH connection: ${GREEN}OK${RESET}"

    # Verify prod uploads dir exists
    log "Verifying prod uploads directory..."
    ssh_cmd "test -d '${PROD_UPLOADS_PATH}'" || {
        warn "Prod uploads directory not found: ${PROD_UPLOADS_PATH}"
        log "  Creating it..."
        ssh_cmd "mkdir -p '${PROD_UPLOADS_PATH}'"
    }
    log "  Prod uploads: ${GREEN}OK${RESET}"
}

# ---------- rsync ----------
do_rsync() {
    local rsync_opts=(
        -avz
        --progress
        --stats
        --human-readable
        --exclude='.gitkeep'
        --exclude='*.tmp'
        --exclude='*.bak'
        --exclude='.DS_Store'
        --exclude='Thumbs.db'
        --exclude='*.log'
    )

    if [[ "$DRY_RUN" == true ]]; then
        rsync_opts+=(--dry-run)
        log "${YELLOW}DRY RUN mode — showing what would be transferred${RESET}"
    fi

    local src dst
    if [[ "$DIRECTION" == "dev-to-prod" ]]; then
        src="${DEV_UPLOADS_PATH}/"
        dst="${SSH_USER}@${SSH_HOST}:${PROD_UPLOADS_PATH}/"
        log "Syncing: ${BOLD}Dev → Prod${RESET}"
        log "  From: ${src}"
        log "  To:   ${PROD_UPLOADS_PATH}/ (on ${SSH_HOST})"
    else
        src="${SSH_USER}@${SSH_HOST}:${PROD_UPLOADS_PATH}/"
        dst="${DEV_UPLOADS_PATH}/"
        log "Syncing: ${BOLD}Prod → Dev${RESET}"
        log "  From: ${PROD_UPLOADS_PATH}/ (on ${SSH_HOST})"
        log "  To:   ${dst}"
    fi

    echo ""
    sshpass -p "$SSH_PASS" rsync "${rsync_opts[@]}" \
        -e "ssh -o StrictHostKeyChecking=no" \
        "$src" "$dst"
    local exit_code=$?

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        log "${GREEN}rsync completed successfully.${RESET}"
    else
        die "rsync failed with exit code ${exit_code}"
    fi
}

# ---------- fix permissions ----------
fix_permissions() {
    if [[ "$DRY_RUN" == true ]]; then
        log "${YELLOW}[DRY RUN]${RESET} Would fix permissions on target"
        return
    fi

    if [[ "$DIRECTION" == "dev-to-prod" ]]; then
        log "Fixing permissions on prod uploads..."
        ssh_cmd "docker exec $PROD_APP chown -R www-data:www-data /var/www/html/${UPLOADS_SUBPATH} 2>/dev/null" || {
            # Fallback: fix on host
            ssh_cmd "chown -R 33:33 '${PROD_UPLOADS_PATH}' 2>/dev/null" || true
        }
        ssh_cmd "docker exec $PROD_APP find /var/www/html/${UPLOADS_SUBPATH} -type d -exec chmod 755 {} \\; 2>/dev/null" || true
        ssh_cmd "docker exec $PROD_APP find /var/www/html/${UPLOADS_SUBPATH} -type f -exec chmod 644 {} \\; 2>/dev/null" || true
        log "  ${GREEN}Permissions fixed on prod.${RESET}"
    else
        log "Fixing permissions on dev uploads..."
        docker exec "$DEV_APP" chown -R www-data:www-data "/var/www/html/${UPLOADS_SUBPATH}" 2>/dev/null || true
        docker exec "$DEV_APP" find "/var/www/html/${UPLOADS_SUBPATH}" -type d -exec chmod 755 {} \; 2>/dev/null || true
        docker exec "$DEV_APP" find "/var/www/html/${UPLOADS_SUBPATH}" -type f -exec chmod 644 {} \; 2>/dev/null || true
        log "  ${GREEN}Permissions fixed on dev.${RESET}"
    fi
}

# ---------- main ----------
main() {
    echo ""
    echo "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
    echo "${BOLD}${BLUE}  Media/Uploads Sync${RESET}"
    echo "${BOLD}${BLUE}═══════════════════════════════════════════════════${RESET}"
    echo ""

    validate

    # Show pre-sync summary
    if [[ "$DIRECTION" == "dev-to-prod" ]]; then
        local dev_count
        dev_count=$(find "$DEV_UPLOADS_PATH" -type f | wc -l)
        log "Dev uploads: ${BOLD}${dev_count}${RESET} files"
    fi

    echo ""
    do_rsync
    fix_permissions

    # Show post-sync summary
    echo ""
    if [[ "$DRY_RUN" != true ]]; then
        if [[ "$DIRECTION" == "dev-to-prod" ]]; then
            local prod_count
            prod_count=$(ssh_cmd "find '${PROD_UPLOADS_PATH}' -type f | wc -l" || echo "unknown")
            log "Prod uploads after sync: ${BOLD}${prod_count}${RESET} files"
        else
            local dev_count_after
            dev_count_after=$(find "$DEV_UPLOADS_PATH" -type f | wc -l)
            log "Dev uploads after sync: ${BOLD}${dev_count_after}${RESET} files"
        fi
    fi

    echo ""
    log "${GREEN}${BOLD}✓ Uploads sync complete!${RESET}"
    echo ""
}

main "$@"
