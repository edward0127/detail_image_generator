module ImageProjects
  class AssetNameNormalizer
    COMMON_IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .webp].freeze
    COMMON_FONT_EXTENSIONS = %w[.ttf .otf .ttc].freeze

    def self.full(name)
      name.to_s.strip.downcase
    end

    def self.extensionless(name)
      File.basename(full(name), File.extname(full(name)))
    end

    def self.default_alias(name)
      stripped_duplicate_suffix(display_base(name)).presence || extensionless(name)
    end

    def self.loose(name)
      stripped_duplicate_suffix(extensionless(name)).delete(" _-")
    end

    def self.with_common_image_extensions(name)
      base = extensionless(name)
      ([ full(name), base ] + COMMON_IMAGE_EXTENSIONS.map { |extension| "#{base}#{extension}" }).uniq
    end

    def self.display_base(name)
      text = name.to_s.strip
      File.basename(text, File.extname(text))
    end

    def self.stripped_duplicate_suffix(name)
      name.to_s.strip.sub(/\s*\(\d+\)\z/, "")
    end
  end
end
