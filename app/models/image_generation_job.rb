class ImageGenerationJob < ApplicationRecord
  ALL_TASKS_ZIP_SCOPE = "all_tasks_zip"
  SELECTED_TASKS_ZIP_SCOPE = "selected_tasks_zip"
  COMPLETED_CACHE_STATUSES = %w[completed completed_with_errors].freeze
  ACTIVE_STATUSES = %w[queued running].freeze
  TERMINAL_STATUSES = %w[completed completed_with_errors failed].freeze
  STALE_RUNNING_AFTER = 1.hour

  belongs_to :image_project
  has_many :generated_images, dependent: :destroy
  has_one_attached :zip_file

  scope :for_zip_cache, ->(input_signature:, generation_scope: ALL_TASKS_ZIP_SCOPE) {
    where(generation_scope: generation_scope, input_signature: input_signature)
  }
  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :completed_cache, -> { where(status: COMPLETED_CACHE_STATUSES) }

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def completed_cache?
    COMPLETED_CACHE_STATUSES.include?(status) && zip_file.attached?
  end

  def downloadable?
    COMPLETED_CACHE_STATUSES.include?(status) && zip_file.attached?
  end

  def failed?
    status == "failed"
  end

  def stale_running?(now: Time.current)
    status == "running" && updated_at.present? && updated_at < STALE_RUNNING_AFTER.ago(now)
  end

  def warnings_list
    parse_json_array(warnings)
  end

  def errors_list
    parse_json_array(error_messages)
  end

  def warnings_list=(value)
    self.warnings = JSON.generate(Array(value))
  end

  def errors_list=(value)
    self.error_messages = JSON.generate(Array(value))
  end

  private

  def parse_json_array(value)
    parsed = JSON.parse(value.presence || "[]")
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end
end
