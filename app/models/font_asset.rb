class FontAsset < ApplicationRecord
  SUPPORTED_EXTENSIONS = %w[.ttf .otf .ttc].freeze

  belongs_to :image_project
  has_one_attached :file

  validates :name, presence: true
  validates :normalized_name, presence: true
  validates :alias_name, presence: true

  before_validation :derive_names

  private

  def derive_names
    self.name = file.filename.to_s if name.blank? && file.attached?
    self.normalized_name = ImageProjects::AssetNameNormalizer.extensionless(name) if name.present?
    self.alias_name = alias_name.to_s.strip if alias_name.present?
    self.alias_name = ImageProjects::AssetNameNormalizer.default_alias(name) if alias_name.blank? && name.present?
    self.alias_name = normalized_name if alias_name.blank? && normalized_name.present?
  end
end
