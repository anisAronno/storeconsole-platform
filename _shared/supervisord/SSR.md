# Inertia SSR Node Process (Supervisor)

The storefront public routes (`shop`, `category`, `products`, `bundles`, `blog`,
`docs`, `pages`) are server-side rendered through Inertia's Node SSR runtime.
Laravel POSTs each page to the SSR server defined by `SSR_URL`
(`http://127.0.0.1:13714` by default); the Node process renders React to HTML
and returns the `#app` body + `<head>` tags.

## Prerequisites

1. Build the SSR bundle (emits `bootstrap/ssr/ssr.js`):

   ```
   npm ci
   npm run build:ssr
   ```

2. Enable SSR in the environment:

   ```
   SSR_ENABLED=true
   SSR_URL=http://127.0.0.1:13714
   ```

## Supervisor program

Each environment runs the SSR server as a long-lived Node process supervised
alongside Horizon. Program blocks live in `conf.d/storeconsole-*.conf`:

```
[program:storeconsole-production-ssr]
command=php /opt/apps/storeconsole-production/artisan inertia:start-ssr --runtime=node --no-interaction
directory=/opt/apps/storeconsole-production
environment=SSR_ENABLED="true",SSR_URL="http://127.0.0.1:13714"
user=www-data
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/storeconsole-production-ssr.log
stopwaitsecs=10
```

`php artisan inertia:start-ssr` launches `node bootstrap/ssr/ssr.js`. The raw
`node bootstrap/ssr/ssr.js` command works too, but the Artisan wrapper resolves
the bundle path from `config/inertia.php` and handles graceful shutdown.

Reload after deploying a new bundle:

```
supervisorctl reread
supervisorctl update
supervisorctl restart storeconsole-production-ssr
```

## Health check / cron watchdog

`inertia:check-ssr` exits non-zero when the SSR server is unreachable. Use it as
a supervisor healthcheck or a cron watchdog that restarts a wedged process:

```
* * * * * www-data php /opt/apps/storeconsole-production/artisan inertia:check-ssr \
  || supervisorctl restart storeconsole-production-ssr
```

The Docker deployment (`deploy/storeconsole.com/docker-compose.yml`) runs the
same `inertia:start-ssr` command in a dedicated `storeconsole-production-ssr`
container with a `fsockopen 127.0.0.1:13714` healthcheck — use either the
container or this supervisor program, not both, on a given host.
