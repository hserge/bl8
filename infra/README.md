# bl8 infrastructure

How `ui/` and `redirect/` actually get deployed: `.github/workflows/deploy.yml` builds both
images, pushes them to GHCR, and SSHes into an existing k3s node to apply the manifests in
`.k8s/`. Postgres and Redis are **not** part of that cluster — they're two separate VMs, set up
once via the scripts in this directory, that both `ui/` and `redirect/` connect to over the
network. Nothing here provisions the k3s node itself or the VMs — that's assumed to already
exist (Proxmox or otherwise); this only covers what runs on top of it.

## Deployment steps, per system

Do these in order the first time (Postgres and Redis have to exist before ui/ or redirect/ can
start; ui/'s schema has to exist before redirect/ can read it). Postgres and Redis are each a
one-off script run, not something `git push` triggers — there's nothing to keep in sync there on
an ongoing basis. ui/ and redirect/, by contrast, are *not* independently deployable from each
other (see the callout after step 4) — both build and deploy on every push to `main`.

### 1. Postgres

1. Provision a Debian/Ubuntu VM reachable from the k3s node's IP/subnet, but from nowhere else,
   and install PostgreSQL 16 on it yourself (matching the `postgres:16-alpine` every other
   environment already targets). `postgres/install.sh` **assumes Postgres is already installed
   and running** and deliberately does not touch `listen_addresses`, `pg_hba.conf`, or the
   firewall — configure those yourself: listen on the interface the k3s node reaches it on, and
   restrict 5432 (via `pg_hba.conf`'s `scram-sha-256` entries and `ufw`/whatever firewall you
   use) to `<k3s node IP>/32` (a `/24` if multiple k3s nodes need access) and nothing else.
2. On it, as root, from `infra/postgres/` (`setup.sql` must sit alongside `install.sh` — the
   script runs it via `psql`): `sudo ./install.sh`. This creates the database and both roles,
   but not the schema — see step 3.
3. Save the script's printed output — `UI_DATABASE_URL` and `REDIRECT_DATABASE_URL` — you won't
   see the passwords again.
4. Apply ui/'s schema once, from any machine that can reach this VM: the script's own printed
   `DATABASE_URL=... pnpm exec drizzle-kit push` command, run from `ui/`.
5. Set the `UI_DATABASE_URL` / `REDIRECT_DATABASE_URL` GitHub secrets (table below).

Re-running `postgres/install.sh` later (e.g. to rotate passwords) is safe — `setup.sql` resets
existing roles' passwords instead of erroring and its grants are idempotent — it re-prints new
connection strings; update the two GitHub secrets to match.

### 2. Redis

1. Provision a second VM, same network constraint as Postgres, and restrict port 6379 to the
   k3s node's IP/subnet yourself (firewall, security group, etc.) — `redis/install.sh`
   deliberately doesn't touch that, same as `postgres/install.sh`.
2. As root: `sudo ./redis/install.sh` (optionally `MAXMEMORY=512mb` etc. — see the script
   header).
3. Save the printed output — `UI_REDIS_URL`, `REDIRECT_REDIS_ADDR`, `REDIRECT_REDIS_PASSWORD`.
4. Set those three as GitHub secrets.

Same as Postgres: re-running the script rotates the password and reprints new values; update the
secrets to match. Nothing needs to be "migrated" here — it's a cache, not a source of truth.

### 3. ui/ (k3s)

First time only:

1. Steps 1–2 above must already be done (ui/ needs both `UI_DATABASE_URL` and `UI_REDIS_URL`).
2. Create a real Google OAuth client (see `ui/README.md`) and set `UI_GOOGLE_CLIENT_ID` /
   `UI_GOOGLE_CLIENT_SECRET`.
3. Generate a real secret and set it as `UI_AUTH_SECRET`: `openssl rand -base64 32`.
4. Get a TLS cert for `admin.bl8.us`, base64 it (`base64 -w0 < cert.pem`), set
   `BL8_UI_TLS_CERT` / `BL8_UI_TLS_KEY`.
5. Set the deployment/registry secrets (`K8S_HOST`, `K8S_SSH_USER`, `SSH_PRIVATE_KEY`,
   `PROXY_*`, `ENCODED_KUBECONFIG_DATA`, `GHCR_PULL_TOKEN`, `SUBMODULES_PAT`) if not already set
   for redirect/ below — they're shared, not per-service.

Every deploy after that: **push to `main`**. `.github/workflows/deploy.yml` builds `ui/`'s
image, pushes it to `ghcr.io/<owner>/bl8-ui`, and applies `.k8s/ui-*.yml` — there's no separate
"deploy just ui/" trigger; a push to `main` deploys both ui/ and redirect/ together (see #4).
Watch the rollout: `kubectl rollout status deployment/bl8-ui -n bl8`.

### 4. redirect/ (k3s)

First time only:

1. Steps 1–2 above must already be done (`REDIRECT_DATABASE_URL`, `REDIRECT_REDIS_ADDR`,
   `REDIRECT_REDIS_PASSWORD`).
2. Get a TLS cert for `bl8.us`, base64 it, set `BL8_REDIRECT_TLS_CERT` / `BL8_REDIRECT_TLS_KEY`.
3. Deployment/registry secrets — same shared set as ui/'s step 5 above, only needs setting once.

Every deploy after that: same as ui/ — **push to `main`** builds+pushes `ghcr.io/<owner>/bl8-
redirect` and applies `.k8s/redirect-*.yml`, in the same workflow run as ui/'s deploy, not a
separate one. Watch the rollout: `kubectl rollout status deployment/bl8-redirect -n bl8`.

> **Deploying just one of ui/ or redirect/ without the other isn't currently possible** — both
> build and deploy together on every push to `main`, even if only one of them actually changed.
> If that becomes a real cost (slow builds, wanting to roll one back independently), split
> `build-and-push` into two path-filtered jobs (`paths: ["ui/**"]` / `paths: ["redirect/**"]`)
> rather than reworking the whole workflow — everything downstream already keys off which
> image/manifest changed, not off a shared job.

## GitHub secrets this workflow needs

Deployment/registry:

| Secret | What |
|---|---|
| `K8S_HOST` | The k3s node's address (SSH target) |
| `K8S_SSH_USER` | SSH username on that node |
| `SSH_PRIVATE_KEY` | SSH key for both `K8S_HOST` and the proxy below |
| `PROXY_HOST` / `PROXY_USERNAME` / `PROXY_PORT` | Bastion/jump host in front of `K8S_HOST`, if the k3s node isn't directly reachable (matches how this workflow's reference was already set up) |
| `ENCODED_KUBECONFIG_DATA` | That cluster's kubeconfig, base64-encoded (`base64 -w0 < kubeconfig`) |
| `GHCR_PULL_TOKEN` | A GitHub PAT with `read:packages`, so the *cluster* can pull images later — the `GITHUB_TOKEN` used to push during CI is scoped to that one workflow run and can't be reused for that |
| `SUBMODULES_PAT` | A GitHub PAT (`repo` scope, or a fine-grained token with Contents: read) with read access to both `bl8-ui` and `bl8-redirect` — `.gitmodules` points at a personal SSH host alias (`git@hserge.github.com:...`) that doesn't resolve on the runner, so the workflow rewrites it to an HTTPS URL authenticated with this token before checking out submodules |

`ui/` (from `postgres/install.sh` and `redis/install.sh`'s own printed output, plus your own
Google OAuth client — see `ui/README.md`):

| Secret | What |
|---|---|
| `UI_DATABASE_URL` | Printed by `postgres/install.sh` |
| `UI_REDIS_URL` | Printed by `redis/install.sh` (already carries its password embedded) |
| `UI_AUTH_SECRET` | A real random secret (`openssl rand -base64 32`) — not the dev placeholder |
| `UI_GOOGLE_CLIENT_ID` / `UI_GOOGLE_CLIENT_SECRET` | From a real Google OAuth client |

`redirect/` (same two scripts):

| Secret | What |
|---|---|
| `REDIRECT_DATABASE_URL` | Printed by `postgres/install.sh` — a *different*, more restricted role than `UI_DATABASE_URL` (SELECT on links, INSERT on click_events only) |
| `REDIRECT_REDIS_ADDR` | Printed by `redis/install.sh` — bare `host:port`, not a URL |
| `REDIRECT_REDIS_PASSWORD` | Printed by `redis/install.sh` |

TLS (base64-encoded PEM cert/key; `base64 -w0 < cert.pem`) — see `.k8s/ingress.yml`'s own
comment if this cluster already runs cert-manager instead, which would make all four of these
unnecessary:

| Secret | What |
|---|---|
| `BL8_UI_TLS_CERT` / `BL8_UI_TLS_KEY` | Certificate for `admin.bl8.us` |
| `BL8_REDIRECT_TLS_CERT` / `BL8_REDIRECT_TLS_KEY` | Certificate for `bl8.us` |

## Why two separate VMs, not one, and not in the cluster

`ui/`'s and `redirect/`'s own constitution already treats Postgres/Redis as external, shared
infrastructure neither service owns (see `ui/README.md`'s Redis section and
`redirect/README.md`'s — `ui/` migrates the schema, `redirect/` only ever reads it). Running
them as their own VMs rather than in-cluster keeps that boundary real instead of just a
comment: stateful data survives a k3s node being rebuilt, redeployed, or scaled independently of
whatever's actually consuming it.

## What each install script actually configures

- **`postgres/install.sh`** (runs `setup.sql`, which must sit next to it) — one database, two
  roles (`bl8_ui` full access, `bl8_redirect` SELECT+INSERT only). Assumes Postgres 16 is
  already installed and running, and deliberately does not touch `listen_addresses`,
  `pg_hba.conf`, or the firewall — that network-level access control is a separate manual step
  now (see "Deployment steps, per system" above), not something this script does for you. Does
  not create the schema itself either — same section.
- **`redis/install.sh`** — Redis (from the official Redis apt repo, packages.redis.io, not the
  distro's own lagging package, so this actually lands the current stable release), `requirepass`
  set to a freshly generated password,
  `maxmemory 256mb` + `maxmemory-policy allkeys-lru`. Same as `postgres/install.sh`, it
  deliberately does not touch the firewall — restricting who can reach 6379 is a separate manual
  step (see "Deployment steps, per system" above). `maxmemory-policy` matters beyond this one
  VM, though: both `ui/`'s and `redirect/`'s own code comments assume an eviction policy exists
  so the no-TTL link cache doesn't grow unbounded forever — nothing anywhere else in this repo
  actually configures that, so this script is where that assumption stops being aspirational.

## Reading the k8s manifests

- **Liveness vs. readiness**, in both `.k8s/ui-deployment.yml` and
  `.k8s/redirect-deployment.yml`: liveness is a bare TCP check, readiness hits each service's own
  `/health`. That split is deliberate, not an oversight — `/health` reports Postgres/Redis
  reachability, and a liveness probe failing there would make k8s restart an otherwise-healthy
  pod during a database blip, which fixes nothing. See each file's own comment.
- **`RATE_LIMIT_RPS` in `.k8s/redirect-configmap.yml`** is per-pod, not fleet-wide (see
  `redirect/internal/ratelimit`'s own package comment) — with `redirect-deployment.yml`'s 2
  replicas, the real ceiling across the Service is roughly double this number.
- **`__IMAGE_UI__` / `__IMAGE_REDIRECT__`** in the two deployment manifests are placeholders the
  workflow `sed`-replaces with a real `ghcr.io/…:<sha>` reference before applying — they're not
  meant to be filled in by hand.
