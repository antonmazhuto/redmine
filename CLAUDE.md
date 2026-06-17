# CLAUDE.md — Redmine API Rate Limiting (take-home slice)

## Repo & scope
Fork of redmine/redmine, branched off tag **6.1.2** (Rails 7.2.3, Ruby 3.2).
Goal: a focused, production-grade slice of Redmine #43881 — **API rate limiting**
(HTTP 429), keyed per API token. All other pillars (token expiration, scopes,
audit log, endpoint control, CORS) are OUT OF SCOPE for this slice.

## How we work (non-negotiable)
- You propose, I validate. You implement; I am the quality gate. Never present
  unverified output as fact.
- Verify, don't guess. For framework behavior (ActionController rate limiting,
  ActiveSupport::Cache#increment) read the actual gem source/docs and cite
  file:line. Do not rely on training memory.
- TDD: failing test first (red) → minimal code (green) → refactor. Show test output.
- Small atomic commits, Conventional Commits, English, one logical change each.
- Match Redmine conventions (Minitest, existing concern/controller patterns).
  No Rubocop regressions.
- No new runtime gems unless justified in the README. Prefer Rails built-ins.
- Stay in scope. Touch only files needed for rate limiting. No drive-by refactors.

## Plan before code
For any non-trivial step, propose a short plan and WAIT for my OK before editing.

## Decision log
Maintain docs/AI_WORKFLOW.md: per key decision record Context → Options →
Decision → Why, and note where I corrected/validated you.

## Commands (Docker, SQLite)
- Run:    docker compose up           # migrates + serves on :3000
- Tests:  docker compose run --rm web bin/rails test test/integration/api_test/rate_limiting_test.rb
- Rubocop: docker compose run --rm web bundle exec rubocop <files>

## Rate-limiting spec
- Scope: **authenticated API requests only.** Key = hashed API token → else
  authenticated user id. NO IP fallback (its reachability depends on
  Setting.login_required?, which is inconsistent — see app_controller
  check_if_login_required at :214-219 → require_login :292-294). Throttling of
  anonymous / invalid-key floods is DEFERRED; note in README that a 401 is not
  throttling (the token lookup still hits the DB).
- Guard: `if: -> { api_request? && User.current.logged? }`. Register the
  before_action AFTER the auth chain so User.current/token is set.
- Default 100 req / 60s, configurable via ENV (REDMINE_API_RATE_LIMIT,
  _WINDOW, _ENABLED). Tests lower the limit.
- Over limit → 429 + Retry-After. RateLimit-Limit/Remaining/Reset on API responses.
- Applies only when api_request? (xml/json). Web/HTML untouched.
- Store: dedicated ActiveSupport::Cache::MemoryStore. VERIFIED in 7.2.3 source:
  MemoryStore#increment preserves the original expires_at on existing keys
  (true fixed window, no TTL-reset footgun). Document the multi-process /
  multi-host limitation (in-process counters) and that a shared store (Redis)
  would be needed at scale — and that some Redis configs DO reset TTL on incr,
  so a window-reset test must guard the semantics.

## Built-in vs custom (decision-log honesty)
VERIFIED in Rails 7.2.3 (action_controller/metal/rate_limiting.rb): the built-in
`rate_limit` key is `"rate-limit:#{controller_path}:#{by}"` (controller_path, NOT
action). We go custom for two real reasons: (1) a unified per-token budget across
ALL API controllers (built-in buckets per controller_path), and (2) RateLimit-* /
Retry-After headers. Built-in does NOT fix any TTL issue — it calls the same
store.increment(expires_in:); correctness comes from the store. State exactly this.

## MVP stop-line (time-box ~2h)
MVP (a complete, defensible slice): Docker (sqlite) + red→green test + window-reset
test + the limiter + 429 + Retry-After + README + curated AI_WORKFLOW.md.
Stretch (only if time remains): RateLimit-* headers, ENV config, separate
adversarial-review phase.
