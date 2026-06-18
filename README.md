# Platform Ops

Shared infrastructure and canonical route map for the server.

## Owns

- `nginx-gateway`
- PostgreSQL
- pgbouncer
- Redis
- shared Reverb websocket service
- Beszel monitoring
- TLS issuance and health checks
- canonical host routing for:
  - `storeconsole.com`
  - `staging.storeconsole.com`
  - `dev.storeconsole.com`
  - `gulfgym.anichur.com`
  - `gulfgym-dev.anichur.com`
  - `focus-backend.anichur.com`
  - `focus-frontend.anichur.com`
  - `focus-web.anichur.com`

## Shared network

- `private_backend`

## Notes

- `dev.storeconsole.com` and `gulfgym-dev.anichur.com` are workspace-only domains
- Hermes stays untouched
- No duplicate infra stacks per app

