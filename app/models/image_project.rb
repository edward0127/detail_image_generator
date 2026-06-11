class ImageProject < ApplicationRecord
  has_many :image_assets, dependent: :destroy
  has_many :font_assets, dependent: :destroy
  has_many :image_generation_jobs, dependent: :destroy
  has_one_attached :preview_file

  validates :name, presence: true

  before_validation :ensure_config_json

  def config_hash
    parsed = JSON.parse(config_json.presence || "{}")
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def update_config!(hash)
    update!(config_json: JSON.pretty_generate(hash))
  end

  def tasks
    config_hash.fetch("tasks", [])
  end

  def latest_generation_job
    image_generation_jobs.order(created_at: :desc).first
  end

  private

  def ensure_config_json
    self.config_json = JSON.pretty_generate(ImageProjects::DefaultConfig.build(name: name.presence || "Untitled Project")) if config_json.blank? || config_json == "{}"
  end
end
