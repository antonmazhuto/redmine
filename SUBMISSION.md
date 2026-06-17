# Submission — Redmine API rate limiting (#43881 slice)

A focused, production-minded slice of [Redmine #43881](https://www.redmine.org/issues/43881):
**per-API-token rate limiting** for the REST API. A caller that exceeds its budget gets
**HTTP 429** with a `Retry-After` header. The other pillars in the ticket (tokens,
scopes, audit log, endpoint control, CORS) are out of scope.

> **Context.** Ruby/Rails is not my primary stack (I work in Node/NestJS and
> React/Next.js, with basic Python). So I leaned on verifying behaviour against the actual
> codebase and gem source, and pinning it down with tests — not on language familiarity.
> Decisions and the source citations are in [docs/AI_WORKFLOW.md](docs/AI_WORKFLOW.md); the
> spec is in [docs/specs/api-rate-limiting.md](docs/specs/api-rate-limiting.md).

## Approach

A small controller concern, [`ApiRateLimit`](app/controllers/concerns/api_rate_limit.rb),
included into `ApplicationController` **after** the auth chain so it runs once
`User.current` and the request token are resolved
([application_controller.rb:64-68](app/controllers/application_controller.rb#L64-L68)). It
adds one `before_action`, guarded `if: -> { api_request? && User.current.logged? }`.

I chose a custom concern over Rails' built-in `rate_limit` and over `rack-attack`, for two
honest reasons (full write-up in the decision log):

- Rails' built-in keys per `controller_path`, i.e. a separate bucket per controller — not a
  single per-token budget across the whole API — and emits no rate-limit headers.
- `rack-attack` runs as middleware *before* Redmine's auth, so it can't see the resolved
  token without re-implementing the lookup; and it's a new runtime dependency.

The built-in does **not** fix any window/TTL correctness issue — it calls the same
`store.increment(key, 1, expires_in:)`. Correctness comes from the store, which I verified
against Rails 7.2.3 source.

## How the rate limiting works

- **Key** — the hashed API token (`api-rate-limit:tok:<sha256>`), falling back to the
  authenticated user id when no token is in the request. The raw key is never stored.
- **Counter** — a dedicated `ActiveSupport::Cache::MemoryStore` (not `Rails.cache`, which is
  a `NullStore` in test/dev). `STORE.increment(key, 1, expires_in: window)`; over the limit
  → set `Retry-After` and `head :too_many_requests`.
- **Fixed window** — verified in Rails 7.2.3 `MemoryStore`: incrementing an existing key
  rebuilds the entry with `expires_at: entry.expires_at`, so the window does not slide on
  each request. A regression test pins this (still throttled just before the window ends,
  reset just after).
- **Config (read from ENV at request time)** — `REDMINE_API_RATE_LIMIT` (default `100`),
  `REDMINE_API_RATE_LIMIT_WINDOW` seconds (default `60`), `REDMINE_API_RATE_LIMIT_ENABLED`
  (default `true`). Reading at request time means config (and tests) take effect without a
  reboot.

## Limits of this approach

- **In-process store.** Counters live in one process's memory, so the budget is enforced
  **per process / per host**. A multi-worker or multi-host deployment would need a shared
  store (Redis/Memcached). Note: some Redis `INCR` setups reset the TTL on increment, which
  would break the fixed window — the window-reset test exists to guard that if the store is
  swapped.
- **Per token, not per endpoint.** One unified budget across all API endpoints. Per-endpoint
  or per-IP limits (the ticket's "maybe") are not implemented.
- **Anonymous / invalid keys are not throttled.** The limiter only runs for authenticated
  API requests. An invalid or missing key returns 401 from the existing auth path — that is
  not throttling, and the token lookup still hits the DB. Throttling unauthenticated floods
  is deferred.
- **Scope.** No admin UI or per-user overrides; configuration is ENV-only.

## Assumptions

- SQLite + Docker is acceptable for running/verifying the slice (the brief leaves the how to
  me). `config/database.yml` is force-added because Redmine gitignores it, so a fresh clone
  can build.
- "Per token" is the right key: the ticket asks for "per token (and maybe per IP/endpoint)",
  and per-token is the part with a clear, testable contract.
- The default 100/60s is a placeholder sane default; real limits would be tuned per
  deployment via the ENV vars.

## How to run and verify

Requires Docker. From the repo root:

```bash
# Run the rate-limiting tests (red→green + window reset)
docker compose run --rm web bin/rails test test/integration/api_test/rate_limiting_test.rb

# (Optional) the whole API integration suite stays green with the limiter on
docker compose run --rm web bin/rails test test/integration/api_test/

# Start the app on http://localhost:3000 (migrates, then serves)
docker compose up
```

The first command exercises the core: requests within the budget return `200`, the request
over the limit returns `429` with a `Retry-After` header, and the budget resets after the
window. See [test/integration/api_test/rate_limiting_test.rb](test/integration/api_test/rate_limiting_test.rb).

To see a 429 by hand against a running server (a fresh DB has the REST API disabled and no
token, so we enable it and mint one). These commands are copy-pasteable and verified:

```bash
# 1. Start the app with a low budget so a handful of requests is enough.
#    (docker-compose.yml passes these vars through to the container.)
REDMINE_API_RATE_LIMIT=3 docker compose up -d

# 2. Enable the REST API and mint an API token for the admin user; capture it.
KEY=$(docker compose exec -T web bin/rails runner \
  'Setting.rest_api_enabled = "1"; \
   u = User.find_by(admin: true); \
   print Token.where(user: u, action: "api").first_or_create!.value')

# 3. Hit an API endpoint 5 times — the 4th and 5th are throttled.
for i in $(seq 1 5); do \
  curl -s -o /dev/null -w "%{http_code} " -H "X-Redmine-API-Key: $KEY" \
    http://localhost:3000/users/current.json; \
done; echo   # -> 200 200 200 429 429

# (optional) inspect the headers on a single request
curl -s -D - -o /dev/null -H "X-Redmine-API-Key: $KEY" \
  http://localhost:3000/users/current.json | grep -iE 'RateLimit-|Retry-After'
# RateLimit-Limit / RateLimit-Remaining / RateLimit-Reset, plus Retry-After on a 429

docker compose down   # stop the app when done
```
