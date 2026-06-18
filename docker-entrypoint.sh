#!/bin/bash
set -e

# Drop a stale server PID from a previous container, if any.
rm -f tmp/pids/server.pid

# Ensure both databases exist and are fully migrated before doing anything else.
# All steps are idempotent: db:create is a no-op if the file exists; db:migrate
# only applies pending migrations. We avoid db:prepare so db/seeds.rb is not run.
#   - development DB backs `docker compose up` (the server on :3000)
#   - test DB backs `bin/rails test` (fixtures load on top of this schema)
echo "==> Preparing development database"
bundle exec rails db:create db:migrate

echo "==> Preparing test database"
RAILS_ENV=test bundle exec rails db:create db:migrate

# Hand off to the container command (server by default, or e.g. `bin/rails test`).
exec "$@"
