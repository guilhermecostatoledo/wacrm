# Docker deployment

The WACRM image contains only the Next.js standalone runtime. Supabase remains an external managed or self-hosted service; database migrations are not executed automatically when the container starts.

## Requirements

- Docker Engine 24+ with Docker Compose v2;
- a configured Supabase project;
- migrations approved and applied through the current repository version;
- a public hostname with HTTPS for production WhatsApp webhooks;
- the five required environment values listed below.

## Required variables

Public build and runtime values:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `NEXT_PUBLIC_SITE_URL`
- `NEXT_PUBLIC_APP_LOCALE`

Runtime-only secrets:

- `SUPABASE_SERVICE_ROLE_KEY`
- `ENCRYPTION_KEY`
- `META_APP_SECRET`

`NEXT_PUBLIC_*` values are compiled into the browser bundle. Changing one of them requires rebuilding the image. Runtime-only secrets require only a container recreation and must never be passed through `docker build --build-arg`.

## First deployment with Docker Compose

```bash
git clone https://github.com/guilhermecostatoledo/wacrm.git
cd wacrm
cp .env.docker.example .env
```

Edit `.env` and replace every placeholder. Generate the encryption key with:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Validate the deployment model before building:

```bash
docker compose config
docker compose build --pull
docker compose up -d
```

Check startup and health:

```bash
docker compose ps
docker compose logs --tail=200 wacrm
curl --fail http://127.0.0.1:3000/api/health
```

A healthy response returns HTTP 200 and `"status":"ok"`. HTTP 503 means one or more required runtime variables are missing. The endpoint reports variable names only, never their values.

## Direct Docker commands

Build:

```bash
docker build \
  --build-arg NEXT_PUBLIC_SUPABASE_URL="https://your-project.supabase.co" \
  --build-arg NEXT_PUBLIC_SUPABASE_ANON_KEY="your-anon-key" \
  --build-arg NEXT_PUBLIC_SITE_URL="https://crm.example.com" \
  --build-arg NEXT_PUBLIC_APP_LOCALE="en" \
  -t wacrm:local .
```

Run with an environment file:

```bash
docker run -d \
  --name wacrm \
  --restart unless-stopped \
  --env-file .env \
  -p 3000:3000 \
  wacrm:local
```

The Compose deployment is preferred because it also applies the non-root, read-only filesystem, dropped capabilities, temporary cache mounts and healthcheck settings.

## Portainer

1. Create a new Stack.
2. Use the repository URL or paste `compose.yaml`.
3. Add every variable from `.env.docker.example` in the stack environment section.
4. Confirm that `NEXT_PUBLIC_SITE_URL` is the final HTTPS URL.
5. Deploy the stack.
6. Confirm the container reports `healthy` and open `/api/health`.

When Portainer builds directly from Git, the public Supabase variables must be available during the build as Compose interpolation values. Runtime secrets remain container environment values.

## Reverse proxy

Expose only the proxy publicly. Forward traffic to container port 3000 and preserve:

- `Host`;
- `X-Forwarded-Host`;
- `X-Forwarded-Proto`;
- the original client IP headers used by your proxy.

Use HTTPS. Set `NEXT_PUBLIC_SITE_URL` to the exact canonical HTTPS origin, without a trailing slash. Configure `ALLOWED_INVITE_HOSTS` when multiple or untrusted host headers can reach the application.

## Database migrations

The application image deliberately does not run schema migrations on startup. Before promoting an image:

1. take a restorable backup;
2. rehearse migrations on an empty database;
3. rehearse them on a restored copy of the current database;
4. apply the approved range using the migration runbook;
5. start the new application image only after schema validation.

See `docs/operations/migration-runbook.md` and `docs/operations/production-readiness.md`.

## Updating

Pin production deployments to an immutable tag or digest, not `latest`.

```bash
docker compose pull
docker compose up -d --remove-orphans
```

When building locally:

```bash
git pull
docker compose build --pull --no-cache
docker compose up -d --remove-orphans
```

A change to `NEXT_PUBLIC_*` requires a rebuild. A runtime-secret change requires:

```bash
docker compose up -d --force-recreate
```

## Rollback

1. stop incoming webhooks and scheduled workers if database compatibility is uncertain;
2. set `WACRM_IMAGE` to the previously verified immutable tag;
3. run `docker compose up -d --force-recreate`;
4. verify `/api/health`, login and inbox processing;
5. when the schema changed incompatibly, restore the matching pre-migration database backup before resuming writes.

Do not run an old application image against a schema that has not been proven backward compatible.

## Troubleshooting

`Container is unhealthy`:

```bash
docker inspect --format '{{json .State.Health}}' wacrm
docker logs --tail=300 wacrm
```

`NEXT_PUBLIC` value appears unchanged:

- rebuild the image; these values are embedded at build time;
- remove the old container and recreate it;
- confirm the proxy/CDN is not serving stale HTML.

`Read-only filesystem error`:

- verify the deployment uses the two tmpfs mounts from `compose.yaml`;
- do not write uploads inside the container; use Supabase Storage or another external object store.
