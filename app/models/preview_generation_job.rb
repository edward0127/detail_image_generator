class PreviewGenerationJob < ApplicationRecord
  SELECTED_TASK_PREVIEW_SCOPE = "selected_task_preview"
  ALL_TASK_PREVIEWS_SCOPE = "all_task_previews"
  ACTIVE_STATUSES = %w[queued running].freeze
  TERMINAL_STATUSES = %w[completed completed_with_errors failed].freeze
  COMPLETED_CACHE_STATUSES = %w[completed completed_with_errors].freeze
  STALE_RUNNING_AFTER = 1.hour
  STALE_RUNNING_MESSAGE = "Preview generation was marked failed because it stopped updating for more than 1 hour."

  belongs_to :image_project

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :for_signature, ->(scope:, input_signature:) {
    where(scope: scope, input_signature: input_signature)
  }

  validates :status, presence: true
  validates :scope, presence: true

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def completed?
    COMPLETED_CACHE_STATUSES.include?(status)
  end

  def stale_running?(now: Time.current)
    status == "running" && updated_at.present? && updated_at < STALE_RUNNING_AFTER.ago(now)
  end

  def selected_task_preview?
    scope == SELECTED_TASK_PREVIEW_SCOPE
  end

  def all_task_previews?
    scope == ALL_TASK_PREVIEWS_SCOPE
  end

  def task_indexes
    parsed = JSON.parse(task_indexes_json.presence || "[]")
    parsed.is_a?(Array) ? parsed.map(&:to_i) : []
  rescue JSON::ParserError
    []
  end

  def task_signatures
    parsed = JSON.parse(task_signatures_json.presence || "{}")
    parsed.is_a?(Hash) ? parsed.transform_keys(&:to_s) : {}
  rescue JSON::ParserError
    {}
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
