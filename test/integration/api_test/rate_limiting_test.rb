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

require_relative '../../test_helper'

class Redmine::ApiTest::RateLimitingTest < Redmine::ApiTest::Base
  # ENV keys the limiter reads for its budget. We snapshot and restore them so
  # the low test limit does not leak into other tests.
  RATE_LIMIT_ENV_KEYS = %w(
    REDMINE_API_RATE_LIMIT
    REDMINE_API_RATE_LIMIT_WINDOW
    REDMINE_API_RATE_LIMIT_ENABLED
  ).freeze

  # Small budget so the test only needs a handful of requests to go over.
  TEST_LIMIT = 3
  TEST_WINDOW = 60

  def setup
    super # Setting.rest_api_enabled = '1'
    @original_env = RATE_LIMIT_ENV_KEYS.index_with { |key| ENV[key] }
    ENV['REDMINE_API_RATE_LIMIT'] = TEST_LIMIT.to_s
    ENV['REDMINE_API_RATE_LIMIT_WINDOW'] = TEST_WINDOW.to_s
    ENV['REDMINE_API_RATE_LIMIT_ENABLED'] = 'true'

    # A fresh user + API token per test means a fresh per-token budget.
    @user = User.generate!
    @token = Token.create!(:user => @user, :action => 'api')
    @headers = {'X-Redmine-API-Key' => @token.value.to_s}
  end

  def teardown
    @original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    User.current = nil
  end

  def test_api_requests_over_the_limit_are_throttled_with_429_and_retry_after
    # Requests up to the limit are served normally.
    TEST_LIMIT.times do
      get '/users/current.json', :headers => @headers
      assert_response :ok
    end

    # The next request exceeds the per-token budget and is throttled.
    get '/users/current.json', :headers => @headers
    assert_response :too_many_requests
    assert response.headers['Retry-After'].present?,
           'expected a Retry-After header on the 429 response'
  end

  def test_rate_limit_headers_are_present_on_a_normal_response
    get '/users/current.json', :headers => @headers
    assert_response :ok
    assert_equal TEST_LIMIT.to_s, response.headers['RateLimit-Limit']
    # One request spent, so limit - 1 remain.
    assert_equal (TEST_LIMIT - 1).to_s, response.headers['RateLimit-Remaining']
    assert_equal TEST_WINDOW.to_s, response.headers['RateLimit-Reset']
  end

  def test_token_budget_resets_after_the_window_elapses
    # Spend the whole budget so the token is throttled.
    (TEST_LIMIT + 1).times { get '/users/current.json', :headers => @headers }
    assert_response :too_many_requests

    # Still throttled before the window has fully elapsed: the fixed window must
    # not slide forward on each request.
    travel(TEST_WINDOW - 1) do
      get '/users/current.json', :headers => @headers
      assert_response :too_many_requests
    end

    # Once the original window has passed, the counter expires and the budget
    # is available again.
    travel(TEST_WINDOW + 1) do
      get '/users/current.json', :headers => @headers
      assert_response :ok
    end
  end

  # --- misconfiguration must be fail-safe (keep limiting), not fail-open/closed ---

  def test_enabled_accepts_non_canonical_truthy_value
    # A common "enable" spelling must not silently disable the limiter.
    ENV['REDMINE_API_RATE_LIMIT_ENABLED'] = '1'
    (TEST_LIMIT + 1).times { get '/users/current.json', :headers => @headers }
    assert_response :too_many_requests
  end

  def test_invalid_window_falls_back_and_still_throttles
    # window=0 would make counters expire immediately (never throttle); fall back.
    ENV['REDMINE_API_RATE_LIMIT_WINDOW'] = '0'
    (TEST_LIMIT + 1).times { get '/users/current.json', :headers => @headers }
    assert_response :too_many_requests
  end

  def test_invalid_limit_falls_back_to_default
    # A non-numeric limit must not coerce to 0 and lock everyone out.
    ENV['REDMINE_API_RATE_LIMIT'] = 'abc'
    get '/users/current.json', :headers => @headers
    assert_response :ok
    assert_equal '100', response.headers['RateLimit-Limit'] # default, not 0
  end
end
