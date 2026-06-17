# AI Workflow & Decision Log — API Rate Limiting (Redmine #43881 slice)

This log records key decisions in **Context → Options → Decision → Why** form, plus a
running note of where the human (Anton) corrected or validated the AI. It exists so the
slice is *defensible*: every framework claim is backed by a working-tree `file:line` or a
verbatim quote from the pinned gem source — not from model memory.

> Note on validation: Ruby/Rails is not my primary stack (I work in Node/NestJS and
> React/Next.js, with basic Python). So validation here leaned on source-verification and
> tests rather than language familiarity — claims are checked against the actual codebase
> and gem source, and behaviour is pinned down with runnable tests.

Stack: Redmine **6.1.2** · Rails **7.2.3** · Ruby **3.2** · Minitest · SQLite (Docker).

---

## Decision 001 — How to implement per-token API rate limiting

### Context

The brief requires the rate-limiting pillar of #43881 only: an authenticated API caller
that exceeds a budget gets **HTTP 429**. The ticket itself asks for limits on "the number
of API requests per token (and maybe per IP address and/or per endpoint)"; there is **no
maintainer implementation guidance**. Scope for this slice: **authenticated API requests,
keyed per API token**. Token expiration, scopes, audit log, endpoint control and CORS are
out of scope.

Before choosing an approach we verified how the request lifecycle actually works on this
codebase (all line numbers re-checked by reading the working tree directly):

| Fact | Location |
| --- | --- |
| `api_request?` is true only for `params[:format]` in `xml`/`json` | `app/controllers/application_controller.rb:723-725` |
| before_action chain (single line): `session_expiration → user_setup → check_if_login_required → set_localization → check_password_change → check_twofa_activation` | `application_controller.rb:64` |
| `user_setup` calls `find_current_user` and assigns `User.current` (auth happens here) | `application_controller.rb:102-108` |
| `find_current_user` runs the API-auth branch only when `rest_api_enabled? && accept_api_auth?` | `application_controller.rb:112-173` |
| per-action API allowlist: `self.accept_api_auth` / `accept_api_auth?` | `application_controller.rb:646` / `:654` |
| API key read from `params[:key]` then `X-Redmine-API-Key` | `application_controller.rb:728-734` |
| key → user: `User.find_by_api_key` → `Token.find_active_user('api', key)` → secure-compare in `find_token` | `user.rb:553` · `token.rb:96` · `token.rb:113-126` |
| API tokens have **no** expiration (`validity_time: nil`) | `token.rb` action def |
| `User.current` is request-scoped (`CurrentAttributes`), defaults to `User.anonymous` | `user.rb:875-877`, `:883-885` |
| API errors render as bare status for xml/json: `render_error` → `format.any { head @status }` | `application_controller.rb:582-595` (`render_403`/`render_404` at `:570-579`; `render_api_errors`→422 at `:777-780`) |
| Tests: Minitest; API tests subclass `Redmine::ApiTest::Base` (sets `rest_api_enabled='1'`); `credentials` helper | `test/test_helper.rb:437`, `:433`, `:428` |
| Reference API test (token + request + assert) | `test/integration/api_test/authentication_test.rb` |
| Cache store is `:null_store` in **test** (and dev by default) — global `Rails.cache` is useless as a counter here | `config/environments/test.rb:36` |
| Precedent for a **dedicated** cache store already exists in the codebase | `config/application.rb:90` (`redmine_search_cache_store = :memory_store`) |

**Two consequences drive the design:**
1. Register the limiter's `before_action` **after** `user_setup` and guard it with
   `if: -> { api_request? && User.current.logged? }`, so the resolved token / user is
   available. No IP fallback: IP reachability depends on `Setting.login_required?`, which
   is inconsistent (`check_if_login_required` `:214` → `require_login` `:273`).
2. The limiter needs its **own** `ActiveSupport::Cache::MemoryStore`, not `Rails.cache`
   (which is `:null_store` in test/dev), mirroring the search-cache precedent.

### Options

**A. Rails built-in `ActionController::RateLimiting#rate_limit`.**
Zero new deps, battle-tested. But verified verbatim against Rails **v7.2.3**
(`actionpack/lib/action_controller/metal/rate_limiting.rb`):

```ruby
count = store.increment("rate-limit:#{controller_path}:#{instance_exec(&by)}", 1, expires_in: within)
```

The key is scoped **per `controller_path`** — so one token gets a *separate* bucket per
controller (issues, projects, …), not a unified API budget — and it emits **no**
`RateLimit-*` / `Retry-After` headers (over-limit default is just `head :too_many_requests`).

**B. `rack-attack` gem.** Mature throttle DSL, runs at the Rack layer. But it is a **new
runtime gem** (CLAUDE.md says avoid unless justified), and it runs as middleware *before*
Redmine's auth chain, so it cannot see `User.current` / the resolved token without
re-implementing token lookup in middleware. Overkill for a single rule.

**C. Custom controller concern + dedicated `MemoryStore`.** A small `before_action`
registered after `user_setup`, guarded `api_request? && User.current.logged?`, keyed off
the hashed API token (else authenticated user id). Counter via a dedicated
`MemoryStore#increment(key, 1, expires_in: window)`; over-limit → `head
:too_many_requests` + `Retry-After`; `RateLimit-Limit/Remaining/Reset` on API responses.
Default 100 req / 60 s, ENV-configurable (`REDMINE_API_RATE_LIMIT`, `_WINDOW`, `_ENABLED`).

### Decision

**Option C — custom concern + dedicated `ActiveSupport::Cache::MemoryStore`.**

### Why

We go custom for **two** real reasons, and we state them honestly:
1. **One unified per-token budget across all API controllers** — the built-in buckets per
   `controller_path` (quote above), which is the wrong granularity for "per token."
2. **`RateLimit-*` / `Retry-After` headers** — the built-in emits none.

**The built-in does _not_ fix any TTL/window bug** — it calls the same
`store.increment(key, 1, expires_in:)` we would. Fixed-window *correctness* comes entirely
from the store, verified verbatim against Rails **v7.2.3**
(`activesupport/lib/active_support/cache/memory_store.rb`, existing-entry branch of
`modify_value`, which `increment` calls):

```ruby
num = entry.value.to_i + amount
entry = Entry.new(num, expires_at: entry.expires_at, version: entry.version)
```

The new `Entry` copies `expires_at` from the prior entry, so incrementing an existing key
**preserves the original window** — a true fixed window with no TTL-reset footgun. (The
first write of a missing key uses the passed `expires_in`.)

**Known limitations (to be documented in the README):**
- In-process counters → **per-process / per-host** only. Multi-worker or multi-host
  deployments need a shared store (Redis/Memcached). Note that some Redis `INCR`
  configurations *do* reset TTL on increment — so a window-reset test must guard the
  semantics if we ever move off `MemoryStore`.
- A 401 on an invalid/anonymous key is **not** throttling (the token lookup still hits the
  DB). Throttling anonymous / invalid-key floods is **deferred** for this slice.

---

## Validation log

- **2026-06-17 — file:line references challenged.** Anton rejected the first plan,
  flagging that the cited line numbers weren't trustworthy (called out `api_request?`).
  Re-verified **every** reference by reading the working tree directly (grep + Read),
  rather than trusting the Explore subagent's output. Result: `api_request?` **is** at
  `:723-725`, `user_setup` `:102-108`, `find_current_user` `:112-173`, `render_error`
  `:582-595`, `render_403` `:570-574`, `render_404` `:576-579`, `api_key_from_request`
  `:728-734`, `find_token` `token.rb:113-126`. The only genuine imprecision in the first
  pass: `accept_api_auth` was lumped as one range — it is two methods, `self.accept_api_auth`
  (`:646`) and `accept_api_auth?` (`:654`); and the chain was cited `64-65` when it is the
  single line `:64` (`:65` is the unrelated `after_action`). Both corrected.
- **2026-06-17 — gem facts must be source-quoted.** Host has no gems installed (Docker dev,
  host Ruby 2.6.10), so framework behavior was verified against the pinned Rails **v7.2.3**
  source on GitHub and recorded above as verbatim quotes rather than paraphrase.
