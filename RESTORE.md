# Store Console Platform — Restore & Rollback Runbook

Full recovery procedures for database, application, nginx, and full server rebuild.

---

## 1. Database Restore

### From Local Backup File

```bash
# Restore a single environment from local dump
gunzip -c /opt/storeconsole-platform/_shared/backups/storeconsole_production_YYYY-MM-DD.dump.gz \
  > /tmp/restore.dump
docker cp /tmp/restore.dump postgres:/tmp/restore.dump
docker exec postgres pg_restore \
  -U "$POSTGRES_SUPERUSER" -d storeconsole_production \
  --clean --if-exists /tmp/restore.dump
docker exec postgres rm /tmp/restore.dump && rm /tmp/restore.dump
```

### From Cloudflare R2

```bash
# Load credentials
source /opt/storeconsole-platform/_shared/.env

# List available backups
AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
AWS_DEFAULT_REGION=auto \
  aws --endpoint-url "$R2_ENDPOINT" s3 ls \
  "s3://$R2_BUCKET/storeconsole.com/production/" --recursive | tail -20

# Download + verify checksum
AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
AWS_DEFAULT_REGION=auto \
  aws --endpoint-url "$R2_ENDPOINT" s3 cp \
  "s3://$R2_BUCKET/storeconsole.com/production/YYYY/MM/DD/storeconsole_production.dump.gz" \
  /tmp/restore.dump.gz

# Restore
gunzip /tmp/restore.dump.gz
docker cp /tmp/restore.dump postgres:/tmp/restore.dump
docker exec postgres pg_restore \
  -U "$POSTGRES_SUPERUSER" -d storeconsole_production \
  --clean --if-exists /tmp/restore.dump
docker exec postgres rm /tmp/restore.dump
rm /tmp/restore.dump
```

### Restore a Specific Table

```bash
docker exec -i postgres pg_restore \
  -U "$POSTGRES_SUPERUSER" -d storeconsole_production \
  --table=orders --clean --if-exists \
  < /path/to/dump.dump
```

---

## 2. Application Rollback (Blue-Green)

The deploy script keeps the previous container available for instant rollback.

### Automatic Rollback

If the deployment healthcheck fails, `deploy-storeconsole.sh` automatically:
1. Restores nginx upstream to the OLD active color
2. Reloads nginx (zero downtime)
3. Sends a failure alert email

### Manual Rollback

```bash
# On the server
ENVIRONMENT=production   # or staging | dev
BASE_DIR=/opt/storeconsole-platform

# Find current active color
ACTIVE=$(cat "$BASE_DIR/"$(env_app_dir $ENVIRONMENT)"/active_color")
INACTIVE=$([ "$ACTIVE" = "blue" ] && echo "green" || echo "blue")

# Switch nginx upstream back to old (inactive) container
cat > "$BASE_DIR/_proxy/nginx/upstreams/storeconsole-${ENVIRONMENT}-active.conf" <<UPSTREAM
upstream storeconsole_${ENVIRONMENT}_active {
    server storeconsole-${ENVIRONMENT}-web-${INACTIVE}:9000 max_fails=3 fail_timeout=10s;
    keepalive 16;
}
UPSTREAM

docker exec nginx-gateway nginx -t
docker exec nginx-gateway nginx -s reload

echo "$INACTIVE" > "$BASE_DIR/"$(env_app_dir $ENVIRONMENT)"/active_color"
ln -sfn "$INACTIVE" "$BASE_DIR/"$(env_app_dir $ENVIRONMENT)"/active"
echo "Rolled back $ENVIRONMENT to $INACTIVE"
```

If the old container was removed, redeploy a previous image:

```bash
PREV_SHA="<previous-git-sha>"   # from ACCESS.local.md or git log
/opt/storeconsole-platform/scripts/deploy-storeconsole.sh \
  "$ENVIRONMENT" "$PREV_SHA" "master" "$PREV_SHA" "manual-rollback"
```

---

## 3. Rollback a Failed Migration

```bash
ENVIRONMENT=production
ACTIVE=$(cat /opt/storeconsole-platform/"$(env_app_dir $ENVIRONMENT)"/active_color)
CONTAINER="storeconsole-${ENVIRONMENT}-web-${ACTIVE}"

# Roll back the last migration
docker exec "$CONTAINER" php artisan migrate:rollback --step=1 --force

# If data is corrupted, restore from pre-migration backup (created automatically by deploy script)
```

---

## 4. Redis Cache Flush

```bash
source /opt/storeconsole-platform/_shared/.env

# Flush cache for ONE environment (DB 1 = cache for all apps, prefix filters)
docker exec redis redis-cli -a "$REDIS_PASSWORD" -n 1 \
  --scan --pattern "storeconsole_prod_*" \
  | xargs -r docker exec -i redis redis-cli -a "$REDIS_PASSWORD" -n 1 DEL

# Flush ALL caches across all apps (DB 1)
docker exec redis redis-cli -a "$REDIS_PASSWORD" -n 1 FLUSHDB

# Flush sessions (DB 2) for staging only
docker exec redis redis-cli -a "$REDIS_PASSWORD" -n 2 \
  --scan --pattern "storeconsole_staging_*" \
  | xargs -r docker exec -i redis redis-cli -a "$REDIS_PASSWORD" -n 2 DEL
```

**Redis DB layout** (4 shared DBs, prefix-based isolation — supports unlimited apps):

| DB | Purpose | All app prefixes |
|----|---------|-----------------|
| 0 | general/default | `storeconsole_prod_`, `storeconsole_staging_`, `storeconsole_dev_`, etc. |
| 1 | cache | same prefixes |
| 2 | sessions | same prefixes |
| 3 | queue/horizon | same prefixes |

---

## 5. nginx Gateway Restore

### nginx Won't Start

```bash
# Test config
docker exec nginx-gateway nginx -t

# Check logs
docker logs nginx-gateway --tail=50

# Remove a broken conf file then reload
rm /opt/storeconsole-platform/_proxy/nginx/conf.d/<broken-file>.conf
docker exec nginx-gateway nginx -t && docker exec nginx-gateway nginx -s reload
```

### nginx Serving Wrong Environment

```bash
# Check upstream pointer
cat /opt/storeconsole-platform/_proxy/nginx/upstreams/storeconsole-production-active.conf

# Fix upstream and reload
cat > /opt/storeconsole-platform/_proxy/nginx/upstreams/storeconsole-production-active.conf <<EOF
upstream storeconsole_production_active {
    server storeconsole-production-web-blue:9000 max_fails=3 fail_timeout=10s;
    keepalive 16;
}
EOF
docker exec nginx-gateway nginx -s reload
```

---

## 6. Full Server Rebuild

```bash
# On a fresh Ubuntu 22.04+ server

# 1. Install Docker
curl -fsSL https://get.docker.com | sh
usermod -aG docker deployer

# 2. Copy ops bundle
scp -r deploy/ deployer@<new-server>:/opt/storeconsole-platform/

# 3. Restore common/.env from ACCESS.local.md
ssh deployer@<new-server> "nano /opt/storeconsole-platform/_shared/.env"

# 4. Create Docker networks
ssh deployer@<new-server> "
docker network create public_edge
docker network create private_backend
docker network create monitoring_internal
"

# 5. Start shared infrastructure
ssh deployer@<new-server> "
cd /opt/storeconsole-platform/_shared && docker compose up -d
"

# 6. Issue TLS certificates
ssh deployer@<new-server> "/opt/storeconsole-platform/scripts/issue-certificates.sh anis904692@gmail.com"

# 7. Render per-env .env files
ssh deployer@<new-server> "/opt/storeconsole-platform/scripts/render-secrets.sh"

# 8. Restore databases from R2 (Section 1 above, for each environment)

# 9. Update GitHub Secret DEPLOY_SSH_HOST and trigger CI/CD:
gh workflow run storeconsole-deploy.yml --field target_branch=master
gh workflow run storeconsole-deploy.yml --field target_branch=staging
gh workflow run storeconsole-deploy.yml --field target_branch=develop
```

---

## 7. Emergency: Site Down Checklist

```bash
# 1. Check containers
docker ps | grep storeconsole-production

# 2. Check PHP-FPM
docker inspect storeconsole-production-web-blue --format '{{.State.Health.Status}}'

# 3. Check nginx upstream
cat /opt/storeconsole-platform/_proxy/nginx/upstreams/storeconsole-production-active.conf

# 4. Check nginx logs
tail -50 /opt/storeconsole-platform/_shared/logs/nginx/error.log

# 5. Check database
docker exec postgres pg_isready -U postgres

# 6. Check Redis
source /opt/storeconsole-platform/_shared/.env
docker exec redis redis-cli -a "$REDIS_PASSWORD" PING

# 7. Check Laravel logs
ACTIVE=$(cat /opt/storeconsole-platform/storeconsole.com/active_color)
docker exec storeconsole-production-web-${ACTIVE} \
  tail -50 /var/www/html/storage/logs/laravel.log

# 8. Restart if needed
cd /opt/storeconsole-platform/storeconsole.com
docker compose restart
docker exec nginx-gateway nginx -s reload
```

---

## 8. Run Fresh Migrations + Seed on Server

```bash
# Find active container for each environment
for env in production staging dev; do
  COLOR=$(cat /opt/storeconsole-platform/"$(env_app_dir "${env}")"/active_color)
  CONTAINER="storeconsole-${env}-web-${COLOR}"
  echo "=== $env ($CONTAINER) ==="
  docker exec "$CONTAINER" php artisan migrate --force
done

# Full fresh seed for dev only (destructive — data loss!)
COLOR=$(cat /opt/storeconsole-platform/dev.storeconsole.com/active_color)
docker exec storeconsole-dev-web-${COLOR} php artisan migrate:fresh --seed --no-interaction

# Run embeddings for production (requires OpenAI key)
COLOR=$(cat /opt/storeconsole-platform/storeconsole.com/active_color)
docker exec storeconsole-production-web-${COLOR} \
  php artisan db:seed \
  --class="AnisAronno\\Intelligence\\Database\\Seeders\\EmbeddingBackfillSeeder" \
  --no-interaction
```
