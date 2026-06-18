# Secret Rotation Notes

Rotate these secrets before final production go-live:

1. `GHCR_TOKEN`
2. `BREVO_SMTP_PASSWORD`
3. `POSTGRES_SUPERPASS`
4. `STORECONSOLE_*_PASSWORD`
5. `PULSE_*_PASSWORD`
6. `REDIS_PASSWORD`
7. `DEV_BASIC_AUTH_PASS`
8. `STAGING_BASIC_AUTH_PASS`
9. `MONITOR_BASIC_AUTH_PASS`
10. `BESZEL_AGENT_KEY`, `BESZEL_AGENT_TOKEN`

## Rotation sequence

1. Update `/opt/storeconsole-platform/common/.env`.
2. Run `bash /opt/storeconsole-platform/scripts/render-secrets.sh`.
3. Restart common services:
   - `cd /opt/storeconsole-platform/common && docker compose -f docker-compose.common.yml up -d`
4. Restart affected app environment services:
   - `cd /opt/storeconsole-platform/apps/storeconsole/<env> && docker compose up -d`
5. Verify with `bash /opt/storeconsole-platform/scripts/healthcheck.sh`.

## Never rotate by committing values

Do not commit any `.env` or secret files into Git.
