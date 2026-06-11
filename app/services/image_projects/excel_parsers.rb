module ImageProjects
  module ExcelParsers
    ColorResult = Struct.new(:background_color, :transparent, :warning, keyword_init: true)

    module_function

    def parse_size(value)
      text = value.to_s.strip
      match = text.match(/(\d+)\s*(?:x|×|\*)\s*(\d+)\s*(?:px)?/i)
      return { "width" => match[1].to_i, "height" => match[2].to_i } if match

      match = text.match(/(?:width|w|宽|宽度)\D*(\d+).*?(?:height|h|高|高度)\D*(\d+)/i)
      return nil unless match

      { "width" => match[1].to_i, "height" => match[2].to_i }
    end

    def parse_color(value)
      text = value.to_s.strip
      return nil if text.blank?

      normalized = text.downcase
      return ColorResult.new(background_color: "transparent", transparent: true) if normalized == "transparent" || text.include?("透明")
      return ColorResult.new(background_color: "#FFFFFF", transparent: false) if normalized == "white" || text.include?("白色")
      return ColorResult.new(background_color: "#000000", transparent: false) if normalized == "black" || text.include?("黑色")

      hex = text.match(/#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\b/)
      return ColorResult.new(background_color: hex[0].upcase, transparent: false) if hex

      ColorResult.new(
        background_color: text,
        transparent: false,
        warning: "Unrecognized background color '#{text}' was preserved as-is."
      )
    end

    def parse_font_size(value)
      text = value.to_s.strip
      match = text.match(/\A(\d+(?:\.\d+)?)\s*(pt|px)?\z/i)
      return nil unless match

      number = match[1].to_f
      number *= 96.0 / 72.0 if match[2].to_s.downcase == "pt"
      number == number.to_i ? number.to_i : number
    end

    def parse_image_reference(value)
      text = clean_reference(value)
      return "" if text.blank?

      patterns = [
        /\A使用\s*图片(?:名|名称)?\s*(?:为|:|：)?\s*(.+)\z/i,
        /\A(?:对应|源|使用)\s*图片\s*(?:名|名称)?\s*(?:为|:|：)?\s*(.+)\z/i,
        /\A图片\s*(?:名|名称)\s*(?:为|:|：)\s*(.+)\z/i,
        /\A(?:use|using)\s+(?:image|picture|photo)(?:\s+(?:named|name))?\s*(?::)?\s*(.+)\z/i,
        /\A(?:source\s+image|image|picture|photo)(?:\s+name)?\s*(?::)\s*(.+)\z/i
      ]

      patterns.each do |pattern|
        match = text.match(pattern)
        return clean_reference(match[1]) if match && clean_reference(match[1]).present?
      end

      text
    end

    def parse_position(value)
      text = value.to_s.strip
      return {} if text.blank?

      if (match = text.match(/距离(?:画布)?(?:顶部|顶端)\s*(\d+)\s*px/i))
        return { "x" => "center", "y" => match[1].to_i }
      end

      if (match = text.match(/(?:top\s*(\d+)\s*px|(\d+)\s*px\s*from\s*(?:canvas\s*)?top|(\d+)\s*px\s*from\s*top)/i))
        return { "x" => "center", "y" => match.captures.compact.first.to_i }
      end

      if (match = text.match(/图层\s*(\d+)\s*下方.*居中/))
        return relative_position("layer#{match[1]}", nil, text)
      end

      if (match = text.match(/(?:below\s*layer\s*(\d+).*center|centered\s*below\s*layer\s*(\d+))/i))
        return relative_position("layer#{match.captures.compact.first}", nil, text)
      end

      if (match = text.match(/在\s*图层\s*(\d+)\s*下面距离\s*(\d+)\s*px/i))
        return relative_position("layer#{match[1]}", match[2].to_i, text)
      end

      if (match = text.match(/(?:(\d+)\s*px\s*below\s*layer\s*(\d+)|below\s*layer\s*(\d+)\D+(\d+)\s*px)/i))
        offset = (match[1] || match[4]).to_i
        layer = match[2] || match[3]
        return relative_position("layer#{layer}", offset, text)
      end

      if text.match?(/\A(?:center|centered|居中)\z/i)
        return { "x" => "center", "y" => "center" }
      end

      {
        "notes" => text,
        "warnings" => [ "Position '#{text}' was not parsed; original text was preserved in notes." ]
      }
    end

    def apply_notes_to_text_layer!(layer, notes)
      text = notes.to_s.strip
      return if text.blank?

      layer["notes"] = [ layer["notes"], text ].compact_blank.join("\n")

      if (match = text.match(/(?:字距拉开至字号的|letter\s*spacing(?:\s*equals)?\s*)\s*(\d+)%/i))
        layer["letterSpacingRatio"] = match[1].to_f / 100.0
      elsif generic_letter_spacing_note?(text) && layer["letterSpacingRatio"].to_f.zero?
        if spread_title_candidate?(layer)
          layer["letterSpacingMode"] = "spread"
          layer["targetTextWidthRatio"] ||= 0.78
          layer["letterSpacingRatio"] = 0.65
        else
          layer["letterSpacingRatio"] = 0.3
        end
      end

      layer["bold"] = true if text.include?("加粗") || text.match?(/\bbold\b|make\s+.+\s+bold/i)
      layer["autoWrap"] = true if text.include?("自动换行") || text.match?(/auto\s*wrap|wrap\s+text/i)
    end

    def generic_letter_spacing_note?(text)
      text.include?("\u5C06\u5B57\u4F53\u95F4\u8DDD\u62C9\u5F00") ||
        text.match?(/increase\s+letter\s+spacing|spread\s+letter\s+spacing/i)
    end
    private_class_method :generic_letter_spacing_note?

    def spread_title_candidate?(layer)
      compact_text = layer["text"].to_s.gsub(/\s+/, "")
      return false unless compact_text.length.between?(2, 20)
      return false unless layer["x"].to_s == "center" && layer["align"].to_s.in?([ "", "center" ])

      layer["fontSize"].to_f >= 40 || layer["name"].to_s.match?(/title|heading/i)
    end
    private_class_method :spread_title_candidate?

    def relative_position(layer_id, offset, original)
      {
        "x" => "center",
        "y" => 0,
        "relativeTo" => layer_id,
        "relativePosition" => "below",
        "notes" => original
      }.tap do |position|
        position["relativeOffset"] = offset if offset.present?
      end
    end
    private_class_method :relative_position

    def clean_reference(value)
      value.to_s.strip
        .sub(/\A["'“”‘’]+/, "")
        .sub(/["'“”‘’。.,，;；\s]+\z/, "")
    end
    private_class_method :clean_reference
  end
end
