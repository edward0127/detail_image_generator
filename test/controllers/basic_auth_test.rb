require "test_helper"

class BasicAuthTest < ActionDispatch::IntegrationTest
  ENV_KEYS = %w[ENABLE_BASIC_AUTH BASIC_AUTH_USERNAME BASIC_AUTH_PASSWORD].freeze

  setup do
    @original_env = ENV_KEYS.to_h { |key| [ key, [ ENV.key?(key), ENV[key] ] ] }
  end

  teardown do
    @original_env.each do |key, (existed, value)|
      existed ? ENV[key] = value : ENV.delete(key)
    end
  end

  test "normal app pages are public when basic auth is disabled" do
    disable_basic_auth

    get root_url

    assert_response :success
  end

  test "normal app pages require credentials when basic auth is enabled" do
    enable_basic_auth

    get root_url

    assert_response :unauthorized
    assert_match "Basic", response.headers["WWW-Authenticate"]
  end

  test "normal app pages accept valid basic auth credentials" do
    enable_basic_auth

    get root_url, headers: basic_auth_headers("preview", "secret")

    assert_response :success
  end

  private

  def enable_basic_auth
    ENV["ENABLE_BASIC_AUTH"] = "true"
    ENV["BASIC_AUTH_USERNAME"] = "preview"
    ENV["BASIC_AUTH_PASSWORD"] = "secret"
  end

  def disable_basic_auth
    ENV_KEYS.each { |key| ENV.delete(key) }
  end

  def basic_auth_headers(username, password)
    {
      "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password)
    }
  end
end
