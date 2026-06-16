class GlobalFontAsset < ApplicationRecord
  SUPPORTED_EXTENSIONS = %w[.ttf .otf .woff .woff2].freeze

  has_one_attached :file

  validates :name, presence: true
  validates :match_name, presence: true
  validates :normalized_name, presence: true
  validate :supported_extension

  before_validation :derive_names

  private

  def derive_names
    self.name = file.filename.to_s if name.blank? && file.attached?
    self.normalized_name = ImageProjects::AssetNameNormalizer.extensionless(name) if name.present?
    self.match_name = match_name.to_s.strip if match_name.present?
    self.match_name = ImageProjects::AssetNameNormalizer.default_alias(name) if match_name.blank? && name.present?
    self.match_name = normalized_name if match_name.blank? && normalized_name.present?
  end

  def supported_extension
    return if name.blank?
    return if SUPPORTED_EXTENSIONS.include?(File.extname(name).downcase)

    errors.add(:name, "must be a supported font file (.ttf, .otf, .woff, or .woff2)")
  end
end
