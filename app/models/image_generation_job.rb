class ImageGenerationJob < ApplicationRecord
  ALL_TASKS_ZIP_SCOPE = "all_tasks_zip"
  SELECTED_TASKS_ZIP_SCOPE = "selected_tasks_zip"
  COMPLETED_CACHE_STATUSES = %w[completed completed_with_errors].freeze

  belongs_to :image_project
  has_many :generated_images, dependent: :destroy
  has_one_attached :zip_file

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
