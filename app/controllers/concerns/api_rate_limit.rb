# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

# Per-API-token rate limiting for the REST API. Once an authenticated caller
# exceeds its budget within a fixed time window, further requests get a 429 with
# a Retry-After header. See docs/specs/api-rate-limiting.md.
module ApiRateLimit
  extend ActiveSupport::Concern

  # Dedicated in-process counter store. Not Rails.cache (a NullStore in
  # test/dev). ActiveSupport::Cache::MemoryStore#increment preserves the
  # original expires_at on existing keys, so this is a true fixed window.
  STORE = ActiveSupport::Cache::MemoryStore.new

  DEFAULT_LIMIT = 100
  DEFAULT_WINDOW = 60
  # Values that explicitly disable the limiter (case-insensitive). Anything else
  # — including a typo or an unexpected spelling — leaves it enabled (fail-safe).
  DISABLED_VALUES = %w(false 0 no off).freeze

  included do
    # Registered after the auth chain (see ApplicationController) so
    # User.current and the request token are already resolved.
    before_action :enforce_api_rate_limit,
                  :if => -> { api_request? && User.current.logged? }
  end

  private

  def enforce_api_rate_limit
    return unless api_rate_limit_enabled?

    limit = api_rate_limit
    window = api_rate_limit_window
    count = STORE.increment(api_rate_limit_key, 1, :expires_in => window)

    response.headers['RateLimit-Limit'] = limit.to_s
    response.headers['RateLimit-Remaining'] = [limit - count, 0].max.to_s
    # Reset is the window length (seconds), matching Retry-After. We do not track
    # the precise window start, so this is the worst-case time to a fresh budget.
    response.headers['RateLimit-Reset'] = window.to_s

    if count > limit
      response.headers['Retry-After'] = window.to_s
      head :too_many_requests
    end
  end

  # Keyed per API token (hashed, so the raw key is never stored), falling back to
  # the authenticated user id when no token is present in the request.
  def api_rate_limit_key
    token = api_key_from_request
    if token.present?
      "api-rate-limit:tok:#{Digest::SHA256.hexdigest(token)}"
    else
      "api-rate-limit:usr:#{User.current.id}"
    end
  end

  # Config is read from ENV at request time so changes (and tests) take effect
  # without a reboot. Parsing is fail-safe: bad values keep the limiter on at the
  # defaults rather than silently disabling or zeroing it.

  # Enabled unless the value is an explicit "off"; a typo never disables it.
  def api_rate_limit_enabled?
    value = ENV['REDMINE_API_RATE_LIMIT_ENABLED']
    value.nil? || !DISABLED_VALUES.include?(value.strip.downcase)
  end

  def api_rate_limit
    positive_int_env('REDMINE_API_RATE_LIMIT', DEFAULT_LIMIT)
  end

  def api_rate_limit_window
    positive_int_env('REDMINE_API_RATE_LIMIT_WINDOW', DEFAULT_WINDOW)
  end

  # A positive integer from ENV. A missing value uses the default silently; a
  # present-but-unusable value (non-numeric or not positive) falls back to the
  # default and logs a warning so the misconfiguration is visible.
  def positive_int_env(name, default)
    raw = ENV[name]
    return default if raw.nil? || raw.strip.empty?

    value = Integer(raw, exception: false)
    return value if value && value > 0

    Rails.logger&.warn("Invalid #{name}=#{raw.inspect}; using default #{default}")
    default
  end
end
