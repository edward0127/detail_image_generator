require "digest"

class ApplicationController < ActionController::Base
  before_action :authenticate_with_optional_basic_auth

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  def authenticate_with_optional_basic_auth
    return unless basic_auth_enabled?

    authenticate_or_request_with_http_basic("Detail Image Generator") do |username, password|
      secure_basic_auth_match?(username, ENV["BASIC_AUTH_USERNAME"]) &&
        secure_basic_auth_match?(password, ENV["BASIC_AUTH_PASSWORD"])
    end
  end

  def basic_auth_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV["ENABLE_BASIC_AUTH"])
  end

  def secure_basic_auth_match?(given, expected)
    return false if given.blank? || expected.blank?

    ActiveSupport::SecurityUtils.secure_compare(
      Digest::SHA256.hexdigest(given.to_s),
      Digest::SHA256.hexdigest(expected.to_s)
    )
  end
end
