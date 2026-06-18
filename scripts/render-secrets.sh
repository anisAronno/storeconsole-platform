#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/opt/storeconsole-platform"
COMMON_ENV="${BASE_DIR}/_shared/.env"
AUTH_DIR="${BASE_DIR}/_proxy/nginx/auth"
PGBOUNCER_USERLIST="${BASE_DIR}/_shared/pgbouncer/userlist.txt"
RUNTIME_LIB="${BASE_DIR}/scripts/lib-runtime.sh"

[ -f "$COMMON_ENV" ] || { echo "Missing $COMMON_ENV" >&2; exit 1; }

set -a
source "$COMMON_ENV"
set +a

mkdir -p "$AUTH_DIR"

# Remove legacy conf files not managed by this repo to prevent nginx duplicate server_name warnings
rm -f "${BASE_DIR}/_proxy/nginx/conf.d/05-local-dev.conf"
rm -f "${BASE_DIR}/_proxy/nginx/conf.d/05-local-dev.conf.disabled"

htpasswd -bc "$AUTH_DIR/dev.htpasswd" "$DEV_BASIC_AUTH_USER" "$DEV_BASIC_AUTH_PASS"
htpasswd -bc "$AUTH_DIR/staging.htpasswd" "$STAGING_BASIC_AUTH_USER" "$STAGING_BASIC_AUTH_PASS"
htpasswd -bc "$AUTH_DIR/monitor.htpasswd" "$MONITOR_BASIC_AUTH_USER" "$MONITOR_BASIC_AUTH_PASS"
if [[ -n "${BOT_BASIC_AUTH_USER:-}" && -n "${BOT_BASIC_AUTH_PASS:-}" ]]; then
  htpasswd -bc "$AUTH_DIR/bot.htpasswd" "$BOT_BASIC_AUTH_USER" "$BOT_BASIC_AUTH_PASS"
fi
if [[ -n "${GULFGYM_DEV_BASIC_AUTH_USER:-}" && -n "${GULFGYM_DEV_BASIC_AUTH_PASS:-}" ]]; then
  htpasswd -bc "$AUTH_DIR/gulfgym-dev.htpasswd" "$GULFGYM_DEV_BASIC_AUTH_USER" "$GULFGYM_DEV_BASIC_AUTH_PASS"
else
  echo "Notice: GULFGYM_DEV_BASIC_AUTH_USER/PASS not set — gulfgym-dev.htpasswd not updated"
fi

escape_userlist_password() {
  local pass="$1"
  pass="${pass//\\/\\\\}"
  pass="${pass//\"/\\\"}"
  printf '%s' "$pass"
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped
  escaped=$(printf '%s' "$value" | sed 's/[&|]/\\&/g')
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

cat > "$PGBOUNCER_USERLIST" <<EOF_USERLIST
"${POSTGRES_SUPERUSER}" "$(escape_userlist_password "$POSTGRES_SUPERPASS")"
"${STORECONSOLE_PROD_USER}" "$(escape_userlist_password "$STORECONSOLE_PROD_PASSWORD")"
"${STORECONSOLE_STAGING_USER}" "$(escape_userlist_password "$STORECONSOLE_STAGING_PASSWORD")"
"${STORECONSOLE_DEV_USER}" "$(escape_userlist_password "$STORECONSOLE_DEV_PASSWORD")"
"${PULSE_PROD_USER}" "$(escape_userlist_password "$PULSE_PROD_PASSWORD")"
"${PULSE_STAGING_USER}" "$(escape_userlist_password "$PULSE_STAGING_PASSWORD")"
"${PULSE_DEV_USER}" "$(escape_userlist_password "$PULSE_DEV_PASSWORD")"
EOF_USERLIST
# Append tenant app users if their credentials are present in the shared env
if [[ -n "${GULFGYM_USER:-}" && -n "${GULFGYM_PASSWORD:-}" ]]; then
  printf '"%s" "%s"\n' "${GULFGYM_USER}" "$(escape_userlist_password "${GULFGYM_PASSWORD}")" >> "$PGBOUNCER_USERLIST"
fi
# 644 so pgbouncer (uid=70) can read the file even when deployer (uid=1001) owns it.
# 600 would cause "Permission denied" inside the container → pgbouncer falls back to
# its entrypoint-generated config which lacks tenant app users.
chmod 644 "$PGBOUNCER_USERLIST"
if [[ "$(id -u)" -eq 0 ]]; then
  chown 70:70 "$PGBOUNCER_USERLIST"
fi
# Sync to common/pgbouncer/ while the container still mounts from there.
# Remove once apply-common-stack.sh migrates pgbouncer to _shared/.
COMMON_PGBOUNCER_DIR="${BASE_DIR}/common/pgbouncer"
if [[ -d "$COMMON_PGBOUNCER_DIR" ]]; then
  cp "$PGBOUNCER_USERLIST" "${COMMON_PGBOUNCER_DIR}/userlist.txt"
  chmod 644 "${COMMON_PGBOUNCER_DIR}/userlist.txt"
  cp "${BASE_DIR}/_shared/pgbouncer/pgbouncer.ini" "${COMMON_PGBOUNCER_DIR}/pgbouncer.ini" 2>/dev/null || true
fi
# Reload pgbouncer to pick up userlist changes (SIGHUP = hot reload, no connection drop)
docker exec pgbouncer pkill -HUP pgbouncer 2>/dev/null || true

SHARED_REVERB_APP_ID="${REVERB_APP_ID:-$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')}"
SHARED_REVERB_APP_KEY="${REVERB_APP_KEY:-$(openssl rand -hex 16)}"
SHARED_REVERB_APP_SECRET="${REVERB_APP_SECRET:-$(openssl rand -hex 24)}"
set_env_value "$COMMON_ENV" "STORECONSOLE_REVERB_IMAGE" "${STORECONSOLE_REVERB_IMAGE:-ghcr.io/anisaronno/storeconsole:latest-production}"
set_env_value "$COMMON_ENV" "REVERB_ENABLED" "true"
set_env_value "$COMMON_ENV" "REVERB_APP_ALLOWED_ORIGINS" "${REVERB_APP_ALLOWED_ORIGINS:-https://storeconsole.com,https://staging.storeconsole.com,https://dev.storeconsole.com,https://gulfgym.anichur.com,https://gulfgym-dev.anichur.com}"
set_env_value "$COMMON_ENV" "REVERB_APP_RATE_LIMITING_ENABLED" "${REVERB_APP_RATE_LIMITING_ENABLED:-true}"
set_env_value "$COMMON_ENV" "REVERB_APP_RATE_LIMIT_MAX_ATTEMPTS" "${REVERB_APP_RATE_LIMIT_MAX_ATTEMPTS:-120}"
set_env_value "$COMMON_ENV" "REVERB_APP_RATE_LIMIT_DECAY_SECONDS" "${REVERB_APP_RATE_LIMIT_DECAY_SECONDS:-60}"
set_env_value "$COMMON_ENV" "REVERB_SCALING_ENABLED" "${REVERB_SCALING_ENABLED:-true}"

for env in production staging dev; do
  # Production env lives alongside its docker-compose; non-prod envs live at app root
  if [[ "$env" == "production" ]]; then
    APP_ENV_FILE="${BASE_DIR}/storeconsole.com/.env"
    APP_ENV_EXAMPLE="${BASE_DIR}/storeconsole.com/.env.example"
  elif [[ "$env" == "staging" ]]; then
    APP_ENV_FILE="${BASE_DIR}/staging.storeconsole.com/.env"
    APP_ENV_EXAMPLE="${BASE_DIR}/staging.storeconsole.com/.env.example"
  else
    APP_ENV_FILE="${BASE_DIR}/dev.storeconsole.com/.env"
    APP_ENV_EXAMPLE="${BASE_DIR}/dev.storeconsole.com/.env.example"
  fi

  if [[ ! -f "$APP_ENV_FILE" ]]; then
    mkdir -p "$(dirname "$APP_ENV_FILE")"
    if [[ -f "$APP_ENV_EXAMPLE" ]]; then
      cp "$APP_ENV_EXAMPLE" "$APP_ENV_FILE"
    else
      touch "$APP_ENV_FILE"
    fi
  fi

  case "$env" in
    production)
      DB_PASS="$STORECONSOLE_PROD_PASSWORD"; PULSE_PASS="$PULSE_PROD_PASSWORD";
      DB_NAME="${STORECONSOLE_PROD_DB:-storeconsole_production}"
      DB_USER="$STORECONSOLE_PROD_USER"
      PULSE_DB_NAME="${PULSE_PROD_DB:-pulse_production}"
      PULSE_DB_USER="$PULSE_PROD_USER"
      APP_ENV_VALUE="production"
      APP_URL_VALUE="https://storeconsole.com"
      SSR_URL_VALUE="http://storeconsole-production-ssr:13714"
      REDIS_PREFIX_VALUE="storeconsole_prod_"
      # Production: DEDICATED Redis DBs 0-3 — isolated from all other apps
      REDIS_DB_VALUE=0; REDIS_CACHE_DB_VALUE=1; REDIS_SESSION_DB_VALUE=2; REDIS_QUEUE_DB_VALUE=3
      ;;
    staging)
      DB_PASS="$STORECONSOLE_STAGING_PASSWORD"; PULSE_PASS="$PULSE_STAGING_PASSWORD";
      DB_NAME="${STORECONSOLE_STAGING_DB:-storeconsole_staging}"
      DB_USER="$STORECONSOLE_STAGING_USER"
      PULSE_DB_NAME="${PULSE_STAGING_DB:-pulse_staging}"
      PULSE_DB_USER="$PULSE_STAGING_USER"
      APP_ENV_VALUE="staging"
      APP_URL_VALUE="https://staging.storeconsole.com"
      SSR_URL_VALUE="http://storeconsole-staging-ssr:13714"
      REDIS_PREFIX_VALUE="storeconsole_staging_"
      # Non-prod shares DBs 4-7; prefix prevents key collisions; future apps continue at 8-11 etc.
      REDIS_DB_VALUE=4; REDIS_CACHE_DB_VALUE=5; REDIS_SESSION_DB_VALUE=6; REDIS_QUEUE_DB_VALUE=7
      ;;
    dev)
      DB_PASS="$STORECONSOLE_DEV_PASSWORD"; PULSE_PASS="$PULSE_DEV_PASSWORD";
      DB_NAME="${STORECONSOLE_DEV_DB:-storeconsole_dev}"
      DB_USER="$STORECONSOLE_DEV_USER"
      PULSE_DB_NAME="${PULSE_DEV_DB:-pulse_dev}"
      PULSE_DB_USER="$PULSE_DEV_USER"
      APP_ENV_VALUE="development"
      APP_URL_VALUE="https://dev.storeconsole.com"
      SSR_URL_VALUE="http://storeconsole-dev-ssr:13714"
      REDIS_PREFIX_VALUE="storeconsole_dev_"
      # Non-prod shares DBs 4-7; prefix prevents key collisions
      REDIS_DB_VALUE=4; REDIS_CACHE_DB_VALUE=5; REDIS_SESSION_DB_VALUE=6; REDIS_QUEUE_DB_VALUE=7
      ;;
  esac

  # SSR disabled for dev+staging (no SSR container) — production only
  SSR_ENABLED_VALUE="false"
  if [[ "$env" == "production" ]]; then SSR_ENABLED_VALUE="true"; fi

  set_env_value "$APP_ENV_FILE" "APP_ENV" "$APP_ENV_VALUE"
  set_env_value "$APP_ENV_FILE" "APP_URL" "$APP_URL_VALUE"
  set_env_value "$APP_ENV_FILE" "SSR_ENABLED" "$SSR_ENABLED_VALUE"
  set_env_value "$APP_ENV_FILE" "SSR_URL" "$SSR_URL_VALUE"
  set_env_value "$APP_ENV_FILE" "INERTIA_SSR_THROW_ON_ERROR" "false"
  set_env_value "$APP_ENV_FILE" "DB_DATABASE" "$DB_NAME"
  set_env_value "$APP_ENV_FILE" "DB_USERNAME" "$DB_USER"
  set_env_value "$APP_ENV_FILE" "DB_PASSWORD" "$DB_PASS"
  set_env_value "$APP_ENV_FILE" "DB_PULSE_DATABASE" "$PULSE_DB_NAME"
  set_env_value "$APP_ENV_FILE" "DB_PULSE_USERNAME" "$PULSE_DB_USER"
  set_env_value "$APP_ENV_FILE" "DB_PULSE_PASSWORD" "$PULSE_PASS"
  set_env_value "$APP_ENV_FILE" "REDIS_PASSWORD" "$REDIS_PASSWORD"
  set_env_value "$APP_ENV_FILE" "REDIS_DB" "$REDIS_DB_VALUE"
  set_env_value "$APP_ENV_FILE" "REDIS_CACHE_DB" "$REDIS_CACHE_DB_VALUE"
  set_env_value "$APP_ENV_FILE" "REDIS_SESSION_DB" "$REDIS_SESSION_DB_VALUE"
  set_env_value "$APP_ENV_FILE" "REDIS_QUEUE_DB" "$REDIS_QUEUE_DB_VALUE"
  set_env_value "$APP_ENV_FILE" "REDIS_PREFIX" "$REDIS_PREFIX_VALUE"
  set_env_value "$APP_ENV_FILE" "MAIL_USERNAME" "$BREVO_SMTP_USERNAME"
  set_env_value "$APP_ENV_FILE" "MAIL_PASSWORD" "$BREVO_SMTP_PASSWORD"
  set_env_value "$APP_ENV_FILE" "MAIL_FROM_ADDRESS" "$ALERT_FROM_EMAIL"
  set_env_value "$APP_ENV_FILE" "ALERT_TO_EMAIL" "$ALERT_TO_EMAIL"
  set_env_value "$APP_ENV_FILE" "ALERT_FROM_EMAIL" "$ALERT_FROM_EMAIL"
  for runtime_key in \
    AI_DEFAULT_PROVIDER \
    AI_DEFAULT_FOR_EMBEDDINGS \
    INTELLIGENCE_ENABLED \
    INTELLIGENCE_CHAT_ENABLED \
    INTELLIGENCE_SUPPORT_ENABLED \
    INTELLIGENCE_ORDER_ENABLED \
    INTELLIGENCE_EMBEDDING_ENABLED \
    INTELLIGENCE_EMBEDDING_PROVIDER \
    INTELLIGENCE_EMBEDDING_DIMENSIONS \
    INTELLIGENCE_PROVIDER \
    OPENAI_API_KEY \
    ANTHROPIC_API_KEY \
    GEMINI_API_KEY \
    VOYAGEAI_API_KEY \
    OPENROUTER_API_KEY \
    COHERE_API_KEY \
    GROQ_API_KEY \
    DEEPSEEK_API_KEY \
    JINA_API_KEY \
    XAI_API_KEY \
    MISTRAL_API_KEY \
    ELEVENLABS_API_KEY \
    OLLAMA_API_KEY \
    OLLAMA_BASE_URL \
    OLLAMA_AI_MODEL \
    OLLAMA_EMBEDDING_MODEL \
    STRIPE_ENABLED \
    STRIPE_KEY \
    STRIPE_SECRET \
    STRIPE_WEBHOOK_SECRET \
    PAYPAL_ENABLED \
    PAYPAL_CLIENT_ID \
    PAYPAL_CLIENT_SECRET \
    PAYPAL_WEBHOOK_ID \
    SSLCOMMERZ_ENABLED \
    SSLCOMMERZ_STORE_ID \
    SSLCOMMERZ_STORE_PASSWORD; do
    set_env_value "$APP_ENV_FILE" "$runtime_key" "${!runtime_key:-}"
  done

  sed -i "s#<STORECONSOLE_[A-Z_]*PASSWORD>#$DB_PASS#g" "$APP_ENV_FILE" || true
  sed -i "s#<PULSE_[A-Z_]*PASSWORD>#$PULSE_PASS#g" "$APP_ENV_FILE" || true
  sed -i "s#<REDIS_PASSWORD>#$REDIS_PASSWORD#g" "$APP_ENV_FILE" || true
  sed -i "s#<BREVO_SMTP_USERNAME>#$BREVO_SMTP_USERNAME#g" "$APP_ENV_FILE" || true
  sed -i "s#<BREVO_SMTP_PASSWORD>#$BREVO_SMTP_PASSWORD#g" "$APP_ENV_FILE" || true
  sed -i "s#<VERIFIED_BREVO_SENDER>#$ALERT_FROM_EMAIL#g" "$APP_ENV_FILE" || true
  sed -i "s#<OPENAI_API_KEY>#${OPENAI_API_KEY:-}#g" "$APP_ENV_FILE" || true
  sed -i "s#<ANTHROPIC_API_KEY>#${ANTHROPIC_API_KEY:-}#g" "$APP_ENV_FILE" || true
  sed -i "s#<GEMINI_API_KEY>#${GEMINI_API_KEY:-}#g" "$APP_ENV_FILE" || true
  sed -i "s#<VOYAGEAI_API_KEY>#${VOYAGEAI_API_KEY:-}#g" "$APP_ENV_FILE" || true

  if grep -q '<SET_FROM_ARTISAN_KEY_GENERATE>' "$APP_ENV_FILE"; then
    key="base64:$(openssl rand -base64 32)"
    sed -i "s#<SET_FROM_ARTISAN_KEY_GENERATE>#$key#g" "$APP_ENV_FILE"
  fi

  set_env_value "$APP_ENV_FILE" "REVERB_APP_ID" "$SHARED_REVERB_APP_ID"
  set_env_value "$APP_ENV_FILE" "REVERB_APP_KEY" "$SHARED_REVERB_APP_KEY"
  set_env_value "$APP_ENV_FILE" "REVERB_APP_SECRET" "$SHARED_REVERB_APP_SECRET"
  set_env_value "$APP_ENV_FILE" "REVERB_HOST" "storeconsole-reverb"
  set_env_value "$APP_ENV_FILE" "REVERB_PORT" "8080"
  set_env_value "$APP_ENV_FILE" "REVERB_SCHEME" "http"
  set_env_value "$APP_ENV_FILE" "VITE_REVERB_APP_KEY" "$SHARED_REVERB_APP_KEY"
  set_env_value "$APP_ENV_FILE" "REVERB_APP_ALLOWED_ORIGINS" "${REVERB_APP_ALLOWED_ORIGINS:-https://storeconsole.com,https://staging.storeconsole.com,https://dev.storeconsole.com,https://gulfgym.anichur.com,https://gulfgym-dev.anichur.com}"
  set_env_value "$APP_ENV_FILE" "REVERB_APP_RATE_LIMITING_ENABLED" "${REVERB_APP_RATE_LIMITING_ENABLED:-true}"
  set_env_value "$APP_ENV_FILE" "REVERB_APP_RATE_LIMIT_MAX_ATTEMPTS" "${REVERB_APP_RATE_LIMIT_MAX_ATTEMPTS:-120}"
  set_env_value "$APP_ENV_FILE" "REVERB_APP_RATE_LIMIT_DECAY_SECONDS" "${REVERB_APP_RATE_LIMIT_DECAY_SECONDS:-60}"
  set_env_value "$APP_ENV_FILE" "REVERB_SCALING_ENABLED" "${REVERB_SCALING_ENABLED:-true}"

  # Secure file permissions: .env files must never be world-readable
  chmod 600 "$APP_ENV_FILE"

done

# Secure common/.env and auth files
chmod 600 "$COMMON_ENV"
chmod 644 "$AUTH_DIR"/*.htpasswd 2>/dev/null || true

# Sync blue-green active symlinks for all Docker-deployed envs
if [[ -f "$RUNTIME_LIB" ]]; then
  source "$RUNTIME_LIB"
  for _env in production staging dev; do
    _env_dir="$(env_app_dir "$_env")"
    [[ -d "$_env_dir" ]] || continue
    _color="$(resolve_active_color "$_env")"
    sync_active_runtime_marker "$_env" "$_color"
  done
else
  for _env_dir in "${BASE_DIR}/storeconsole.com" "${BASE_DIR}/staging.storeconsole.com" "${BASE_DIR}/dev.storeconsole.com"; do
    [[ -d "$_env_dir" ]] || continue
    _color="$(cat "${_env_dir}/active_color" 2>/dev/null || echo blue)"
    ln -sfn "$_color" "${_env_dir}/active"
  done
fi


echo "Secret rendering completed."
