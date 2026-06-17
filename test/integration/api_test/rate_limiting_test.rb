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

  def setup
    super # Setting.rest_api_enabled = '1'
    @original_env = RATE_LIMIT_ENV_KEYS.index_with { |key| ENV[key] }
    ENV['REDMINE_API_RATE_LIMIT'] = TEST_LIMIT.to_s
    ENV['REDMINE_API_RATE_LIMIT_WINDOW'] = '60'
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
end
