# Spec — API Rate Limiting (Redmine #43881 slice)

A focused slice: authenticated API callers get a per-token request budget; over the budget
returns **HTTP 429**. Scope, decision, and verified framework facts live in
[../AI_WORKFLOW.md](../AI_WORKFLOW.md) (Decision 001). This spec is the *what* before tests.

Legend: **[MVP]** required for a defensible slice · **[Nice]** stretch · **[Done]** shipped.

---

## 1. The concern & where it hooks  **[MVP]**

A controller concern `ApiRateLimit` (e.g. `app/controllers/concerns/api_rate_limit.rb`),
included into `ApplicationController`. It registers **one** `before_action`, placed **after**
the existing auth chain so `User.current` / the token are already resolved
(`application_controller.rb:64`, auth set in `user_setup` `:102-108`):

```
before_action :enforce_api_rate_limit, if: -> { api_request? && User.current.logged? }
```

Behaviour per request, when the guard passes:
1. Build the key (§2). If no key can be derived → do nothing (let it through).
2. `count = store.increment(key, 1, expires_in: window)` on the dedicated store (§4).
3. Set `RateLimit-*` headers (§3, **[Done]**).
4. If `count > limit` → render 429 (§3) and halt; else continue.

The guard `api_request? && User.current.logged?` is what keeps web/HTML and
anonymous/invalid-key requests **out** of the limiter entirely.

## 2. The rate-limit key  **[MVP]**

Key = the **hashed API token** when the request authenticated via an API key; otherwise the
**authenticated user id**. Shape: `"api-rate-limit:tok:<sha256>"` / `"api-rate-limit:usr:<id>"`.

- Hash the token (`Digest::SHA256`) so raw key material never sits in the cache.
- **No IP fallback.** IP reachability depends on `Setting.login_required?`, which is
  inconsistent (`check_if_login_required:214` → `require_login:273`); an unauthenticated
  flood is a 401 path, not throttling — explicitly deferred.
- Anonymous / invalid keys never reach this code (guard requires `User.current.logged?`),
  so they get **no** bucket.

> To verify: the cleanest source for "which token authenticated this request" — reuse
> `api_key_from_request` (`application_controller.rb:728`) vs. reading from the resolved
> `Token`. Confirm before writing the key builder.

## 3. The 429 response  **[MVP]**

Follow the codebase idiom for API errors (`render_error` → `format.any { head @status }`,
`application_controller.rb:582-595`): a bare status, no body.

- Status: **429 Too Many Requests** (`head :too_many_requests`).
- **`Retry-After`**: seconds until the current window resets (integer).  **[MVP]**
- **`RateLimit-Limit` / `RateLimit-Remaining` / `RateLimit-Reset`** on API responses
  (`RateLimit-Remaining` floored at 0; set on both 200 and 429 paths).  **[Done]**

## 4. Fixed window via the store  **[MVP]**

A **dedicated** `ActiveSupport::Cache::MemoryStore` (not `Rails.cache`, which is
`:null_store` in test/dev — `config/environments/test.rb:36`), mirroring the existing
`redmine_search_cache_store` precedent (`config/application.rb:90`).

Window correctness leans entirely on verified Rails v7.2.3 `MemoryStore#increment`
behaviour: incrementing an existing key copies `expires_at` from the prior entry
(`Entry.new(num, expires_at: entry.expires_at, ...)`), so the window does **not** slide on
each hit — a true fixed window. First write of a missing key sets `expires_in: window`.
(Full quote in AI_WORKFLOW Decision 001.)

`Retry-After` / `RateLimit-Reset` need the window's remaining time. MemoryStore doesn't
expose a public TTL read. **Shipped decision:** keep it simple — both report the full
**window length** (seconds), not the precise time-to-reset. This is the worst-case time to
a fresh budget and avoids tracking a per-window start timestamp. A precise countdown would
need first-seen-timestamp tracking; deferred as not worth the complexity for this slice.

> To verify: that a single dedicated `MemoryStore` instance is shared across requests in the
> test/dev server (it is per-process — acceptable, and the documented limitation). Confirm
> the instance lifecycle (initializer constant vs. memoized class attr) during implementation.

## 5. Config  **[MVP]**

| Setting | ENV var | Default |
| --- | --- | --- |
| Limit (requests / window) | `REDMINE_API_RATE_LIMIT` | `100` |
| Window (seconds) | `REDMINE_API_RATE_LIMIT_WINDOW` | `60` |
| Enabled | `REDMINE_API_RATE_LIMIT_ENABLED` | `true` |

Read once at boot (coerce to int / bool). When disabled, the `before_action` is a no-op.
Tests lower the limit (e.g. 2–3) to exercise the boundary cheaply.

## 6. Not doing (this slice)

- No per-IP and no per-endpoint limits (ticket's "maybe" — out of scope).
- No throttling of anonymous / invalid-key traffic (401 ≠ throttle; token lookup still
  hits the DB).
- No shared/distributed store (Redis/Memcached) — single-process MemoryStore only;
  multi-process/host scaling is a documented limitation.
- No admin UI, settings-screen toggle, or per-user limit overrides — ENV only.
- No token-expiration, scopes, audit log, endpoint control, or CORS (other #43881 pillars).

## 7. Items resolved during implementation

1. **Token source for the key** — used `api_key_from_request` (header/param token), hashed;
   falls back to `User.current.id`. **[Done]**
2. **`Retry-After` / `RateLimit-Reset`** — report the full window length, no timestamp
   tracking (see §4). **[Done]**
3. **Dedicated store lifecycle** — a single per-process `MemoryStore` constant; cleared in
   the global test teardown so counts don't leak across tests. **[Done]**
4. **Scope shipped**: all of §1–§5, the 429 + `Retry-After` **and** the `RateLimit-*`
   header trio. The full API integration suite stays green with the limiter enabled.
