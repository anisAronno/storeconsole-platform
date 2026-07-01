# GitHub Secrets Template

Set these in repository `Settings -> Secrets and variables -> Actions`.

| Secret | Value |
|---|---|
| `DEPLOY_SSH_HOST` | `135.125.131.135` |
| `DEPLOY_SSH_USER` | `deployer` |
| `DEPLOY_SSH_PORT` | `22` |
| `DEPLOY_SSH_PRIVATE_KEY` | private key text for deploy key (PEM) |
| `GHCR_USERNAME` | optional override (defaults to `${{ github.actor }}` in workflow) |
| `GHCR_TOKEN` | optional for CI push (workflow falls back to `${{ github.token }}`); still required on server `common/.env` for deploy pull |
| `REVERB_APP_KEY` | same shared value as `REVERB_APP_KEY` in all three server `.env` files |
| `ALERT_TO_EMAIL` | `hello@anichur.com` |
| `BREVO_SMTP_HOST` | `smtp-relay.brevo.com` |
| `BREVO_SMTP_PORT` | `587` |
| `BREVO_SMTP_USERNAME` | your Brevo SMTP username |
| `BREVO_SMTP_PASSWORD` | your Brevo SMTP password |
| `ALERT_FROM_EMAIL` | verified Brevo sender email |
| `ALERT_FROM_NAME` | `Store Console Server` |
| `MONITOR_BASIC_AUTH_USER` | optional (monitor nginx basic auth disabled in current repo config) |
| `MONITOR_BASIC_AUTH_PASS` | optional (monitor nginx basic auth disabled in current repo config) |
| `DEV_BASIC_AUTH_USER` | strong username |
| `DEV_BASIC_AUTH_PASS` | strong random password |
| `STAGING_BASIC_AUTH_USER` | strong username |
| `STAGING_BASIC_AUTH_PASS` | strong random password |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 access key for backup upload, if CI-side secret sync is used |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 secret access key for backup upload, if CI-side secret sync is used |

## GHCR token requirements

Create a fine-grained personal access token for account `anisaronno` (recommended):

- Resource owner: `anisaronno`
- Repository access: only this repository
- Permissions:
  - Repository permissions: `Contents: Read`
  - Account permissions: `Packages: Read and Write`

Use that token as:

- GitHub Actions secret `GHCR_TOKEN` (optional, fallback exists)
- Server value `GHCR_TOKEN` in `/opt/storeconsole-platform/_shared/.env` (required for pull on server)

## Deploy SSH key

1. Generate key pair on your machine:
   - `ssh-keygen -t ed25519 -f ~/.ssh/storeconsole_deploy -C "github-actions-storeconsole"`
2. Add public key to server:
   - append `~/.ssh/storeconsole_deploy.pub` into `/home/deployer/.ssh/authorized_keys`
3. Put private key content from `~/.ssh/storeconsole_deploy` into GitHub secret `DEPLOY_SSH_PRIVATE_KEY`.
