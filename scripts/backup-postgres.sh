#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-all}"
BASE_DIR="/opt/storeconsole-platform"
COMMON_ENV="${BASE_DIR}/_shared/.env"
BACKUP_DIR="${BASE_DIR}/_shared/backups"
SCRIPTS_DIR="${BASE_DIR}/scripts"

[[ -f "$COMMON_ENV" ]] || { echo "Missing $COMMON_ENV" >&2; exit 1; }

set -a
source "$COMMON_ENV"
set +a

DATE_UTC="$(date -u +%Y%m%dT%H%M%SZ)"
YEAR="$(date -u +%Y)"
MONTH="$(date -u +%m)"
DAY="$(date -u +%d)"
DAILY_DIR="${BACKUP_DIR}/daily"
WEEKLY_DIR="${BACKUP_DIR}/weekly"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-40}"
PURGE_LOCAL_AFTER_UPLOAD="${BACKUP_PURGE_LOCAL_AFTER_UPLOAD:-true}"
R2_STRICT_MODE="${R2_STRICT_MODE:-false}"
R2_BUCKET_EFFECTIVE="${R2_BUCKET:-storeconsole}"
R2_PREFIX_EFFECTIVE="${R2_PREFIX:-storeconsole.com}"
R2_ENDPOINT_EFFECTIVE="${R2_ENDPOINT:-}"
mkdir -p "$DAILY_DIR" "$WEEKLY_DIR"

is_true() {
  case "${1:-}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On|enabled|ENABLED|Enabled) return 0 ;;
    *) return 1 ;;
  esac
}

r2_upload_enabled() {
  if [[ -n "${R2_ENABLED:-}" ]] && ! is_true "${R2_ENABLED}"; then
    return 1
  fi

  [[ -n "${R2_ENDPOINT_EFFECTIVE}" ]] || return 1
  [[ -n "${R2_BUCKET_EFFECTIVE}" ]] || return 1
  [[ -n "${R2_ACCESS_KEY_ID:-}" ]] || return 1
  [[ -n "${R2_SECRET_ACCESS_KEY:-}" ]] || return 1
  command -v aws >/dev/null 2>&1 || return 1

  return 0
}

aws_r2() {
  AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}" \
  AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}" \
  AWS_DEFAULT_REGION="auto" \
    aws --endpoint-url "${R2_ENDPOINT_EFFECTIVE}" "$@"
}

send_backup_alert() {
  local status="$1"
  local message="$2"
  local uploaded="$3"
  local payload
  payload="$(mktemp)"
  cat > "$payload" <<JSON
{
  "target": "${TARGET}",
  "status": "${status}",
  "message": "${message}",
  "r2_uploaded": ${uploaded},
  "local_purged": $(is_true "$PURGE_LOCAL_AFTER_UPLOAD" && echo true || echo false),
  "retention_days": ${RETENTION_DAYS},
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

  if [[ "$status" == "success" ]]; then
    ALERT_SUBJECT="[STORECONSOLE][BACKUP SUCCESS] ${TARGET}"
    ALERT_SEV="info"
    ALERT_TYPE="backup_success"
  else
    ALERT_SUBJECT="[STORECONSOLE][BACKUP FAILED] ${TARGET}"
    ALERT_SEV="critical"
    ALERT_TYPE="backup_failure"
  fi

  ALERT_FROM_EMAIL="${ALERT_FROM_EMAIL:-}" \
  ALERT_FROM_NAME="${ALERT_FROM_NAME:-Store Console Server}" \
  ALERT_TO_EMAIL="${ALERT_TO_EMAIL:-hello@anichur.com}" \
  BREVO_SMTP_HOST="${BREVO_SMTP_HOST:-smtp-relay.brevo.com}" \
  BREVO_SMTP_PORT="${BREVO_SMTP_PORT:-587}" \
  BREVO_SMTP_USERNAME="${BREVO_SMTP_USERNAME:-}" \
  BREVO_SMTP_PASSWORD="${BREVO_SMTP_PASSWORD:-}" \
  "$SCRIPTS_DIR/send-alert.sh" "$ALERT_TYPE" "$ALERT_SEV" "$ALERT_SUBJECT" "$payload" || true

  rm -f "$payload"
}

db_environment() {
  case "$1" in
    storeconsole_production|pulse_production) echo "production" ;;
    storeconsole_staging|pulse_staging) echo "staging" ;;
    storeconsole_dev|pulse_dev) echo "dev" ;;
    gulfgym) echo "gulfgym" ;;
    *) echo "misc" ;;
  esac
}

select_dbs() {
  case "$TARGET" in
    production) printf '%s\n' "${STORECONSOLE_PROD_DB:-storeconsole_production}" "${PULSE_PROD_DB:-pulse_production}" ;;
    staging) printf '%s\n' "${STORECONSOLE_STAGING_DB:-storeconsole_staging}" "${PULSE_STAGING_DB:-pulse_staging}" ;;
    dev) printf '%s\n' "${STORECONSOLE_DEV_DB:-storeconsole_dev}" "${PULSE_DEV_DB:-pulse_dev}" ;;
    gulfgym) printf '%s\n' "${GULFGYM_DB:-gulfgym}" ;;
    all) printf '%s\n' \
      "${STORECONSOLE_PROD_DB:-storeconsole_production}" \
      "${STORECONSOLE_STAGING_DB:-storeconsole_staging}" \
      "${STORECONSOLE_DEV_DB:-storeconsole_dev}" \
      "${PULSE_PROD_DB:-pulse_production}" \
      "${PULSE_STAGING_DB:-pulse_staging}" \
      "${PULSE_DEV_DB:-pulse_dev}" \
      "${GULFGYM_DB:-gulfgym}" ;;
    cleanup) return 0 ;;
    *) echo "invalid target: $TARGET" >&2; exit 1 ;;
  esac
}

cleanup_local_retention() {
  find "$DAILY_DIR" -type f \( -name '*.dump.gz' -o -name '*.sha256' \) -mtime +"$RETENTION_DAYS" -delete
  find "$WEEKLY_DIR" -type f \( -name '*.dump.gz' -o -name '*.sha256' \) -mtime +"$RETENTION_DAYS" -delete
}

purge_local_backups() {
  find "$DAILY_DIR" -type f \( -name '*.dump.gz' -o -name '*.sha256' \) -delete
  find "$WEEKLY_DIR" -type f \( -name '*.dump.gz' -o -name '*.sha256' \) -delete
}

cleanup_r2() {
  r2_upload_enabled || return 0

  local cutoff query keys key
  cutoff="$(date -u -d "${RETENTION_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"${RETENTION_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"
  query="Contents[?LastModified<=\`${cutoff}\`].Key"

  keys="$(aws_r2 s3api list-objects-v2 --bucket "$R2_BUCKET_EFFECTIVE" --prefix "${R2_PREFIX_EFFECTIVE}/" --query "$query" --output text 2>/dev/null || true)"
  [[ -n "$keys" ]] || return 0

  for key in $keys; do
    [[ -n "$key" && "$key" != "None" ]] || continue
    aws_r2 s3 rm "s3://${R2_BUCKET_EFFECTIVE}/${key}" >/dev/null || true
  done
}

if [[ "$TARGET" == "cleanup" ]]; then
  cleanup_local_retention
  cleanup_r2
  send_backup_alert "success" "backup cleanup completed" false
  exit 0
fi

STATUS="success"
MSG=""
UPLOADED=false
R2_ENABLED_EFFECTIVE=false
if r2_upload_enabled; then
  R2_ENABLED_EFFECTIVE=true
fi

DBS=()
while IFS= read -r db; do
  [[ -n "$db" ]] && DBS+=("$db")
done < <(select_dbs)

if [[ "$R2_ENABLED_EFFECTIVE" != true ]]; then
  if is_true "$R2_STRICT_MODE"; then
    STATUS="failure"
    MSG="R2 backup is not enabled or missing endpoint/credentials/awscli"
  else
    MSG="R2 upload skipped: missing endpoint/credentials/awscli"
  fi
fi

if [[ "$STATUS" == "success" ]]; then
  for db in "${DBS[@]}"; do
    out_file="${DAILY_DIR}/${db}-${DATE_UTC}.dump"
    gz_file="${out_file}.gz"
    manifest_file="${gz_file}.sha256"

    docker exec -e PGPASSWORD="$POSTGRES_SUPERPASS" postgres pg_dump -h 127.0.0.1 -U "$POSTGRES_SUPERUSER" -d "$db" -Fc -f "/tmp/${db}.dump"
    docker cp "postgres:/tmp/${db}.dump" "$out_file"

    if ! docker exec -e PGPASSWORD="$POSTGRES_SUPERPASS" postgres pg_restore -h 127.0.0.1 -U "$POSTGRES_SUPERUSER" -d "$db" --list "/tmp/${db}.dump" >/dev/null 2>&1; then
      STATUS="failure"
      MSG="backup verification failed for ${db}"
      docker exec postgres rm -f "/tmp/${db}.dump" >/dev/null 2>&1 || true
      break
    fi

    docker exec postgres rm -f "/tmp/${db}.dump"

    gzip -f "$out_file"
    sha256sum "$gz_file" > "$manifest_file"

    if [[ "$R2_ENABLED_EFFECTIVE" == true ]]; then
      env_name="$(db_environment "$db")"
      object_prefix="${R2_PREFIX_EFFECTIVE}/${env_name}/${YEAR}/${MONTH}/${DAY}"

      if ! aws_r2 s3 cp "$gz_file" "s3://${R2_BUCKET_EFFECTIVE}/${object_prefix}/$(basename "$gz_file")" >/dev/null; then
        STATUS="failure"
        MSG="R2 upload failed for ${db} dump"
        break
      fi

      if ! aws_r2 s3 cp "$manifest_file" "s3://${R2_BUCKET_EFFECTIVE}/${object_prefix}/$(basename "$manifest_file")" >/dev/null; then
        STATUS="failure"
        MSG="R2 upload failed for ${db} manifest"
        break
      fi

      UPLOADED=true
    fi
  done
fi

if [[ "$STATUS" == "success" ]]; then
  if [[ "$R2_ENABLED_EFFECTIVE" == true ]]; then
    cleanup_r2
  fi

  if [[ "$R2_ENABLED_EFFECTIVE" == true ]] && is_true "$PURGE_LOCAL_AFTER_UPLOAD"; then
    purge_local_backups
  else
    cleanup_local_retention

    if [[ "$(date -u +%u)" == "7" ]]; then
      for db in "${DBS[@]}"; do
        latest_daily="$(ls -1t "${DAILY_DIR}/${db}-"*.dump.gz 2>/dev/null | head -n1 || true)"
        if [[ -n "$latest_daily" ]]; then
          cp "$latest_daily" "${WEEKLY_DIR}/$(basename "$latest_daily")"
          cp "${latest_daily}.sha256" "${WEEKLY_DIR}/$(basename "${latest_daily}.sha256")" 2>/dev/null || true
        fi
        old_weekly="$(ls -1t "${WEEKLY_DIR}/${db}-"*.dump.gz 2>/dev/null | tail -n +5 || true)"
        if [[ -n "$old_weekly" ]]; then
          printf '%s\n' "$old_weekly" | xargs -r rm -f
          printf '%s\n' "$old_weekly" | sed 's/$/.sha256/' | xargs -r rm -f
        fi
      done
    fi
  fi
fi

send_backup_alert "$STATUS" "$MSG" "$UPLOADED"
if [[ "$STATUS" != "success" && -n "$MSG" ]]; then
  echo "$MSG" >&2
fi
[[ "$STATUS" == "success" ]]
