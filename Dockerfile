# Redmine 6.1.2 — API rate-limiting slice. Dev/test image on Ruby 3.3.
# Gemfile allows ruby >= 3.2.0, < 3.5.0; we pin 3.3.x.
FROM ruby:3.3-slim

ENV LANG=C.UTF-8 \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3

# System packages: build toolchain for native gem extensions, sqlite, git, tzdata.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      git \
      libsqlite3-dev \
      libyaml-dev \
      zlib1g-dev \
      pkg-config \
      tzdata && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/redmine

# The Gemfile resolves database gems by reading config/database.yml, so that file
# must be present before `bundle install`. Copy just the bundle inputs first so
# this layer is cached across application code changes.
COPY Gemfile ./
COPY config/database.yml config/database.yml
RUN bundle install

# Application code. In docker-compose this is shadowed by a bind mount for live
# editing; in a plain `docker build` it bakes the app in.
COPY . .

EXPOSE 3000
ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
