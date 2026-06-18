module ImageProjects
  module ExcelParsers
    ColorResult = Struct.new(:background_color, :transparent, :warning, keyword_init: true)
    PartialBoldMatch = Struct.new(:status, :phrase, :warning, keyword_init: true)

    PARTIAL_BOLD_UNMATCHED_WARNING = "Partial bold note was found, but the target word could not be matched safely.".freeze

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

    def apply_notes_to_text_layer!(layer, notes, warnings: nil)
      text = notes.to_s.strip
      return if text.blank?

      layer["notes"] = [ layer["notes"], text ].compact_blank.join("\n")

      if (match = text.match(/(?:\u5B57\u8DDD\u62C9\u5F00\u81F3\u5B57\u53F7\u7684|letter\s*spacing(?:\s*equals)?\s*)\s*(\d+)%/i))
        layer["letterSpacingRatio"] = match[1].to_f / 100.0
      elsif generic_letter_spacing_note?(text) && layer["letterSpacingRatio"].to_f.zero?
        layer["letterSpacingRatio"] = 0.3
      end

      if explicit_spread_to_width_note?(text)
        layer["letterSpacingMode"] = "spread"
        layer["targetTextWidthRatio"] = target_text_width_ratio(text) || layer["targetTextWidthRatio"] || 0.78
        layer["letterSpacingRatio"] = 0.3 if layer["letterSpacingRatio"].to_f.zero?
      end

      partial_bold_status = apply_partial_bold_note!(layer, text, warnings: warnings)
      layer["bold"] = true if partial_bold_status.nil? && whole_layer_bold_note?(text)
      layer["autoWrap"] = true if text.include?("自动换行") || text.match?(/auto\s*wrap|wrap\s+text/i)
    end

    def apply_partial_bold_note!(layer, text, warnings: nil)
      candidates = partial_bold_phrase_candidates(text)
      if candidates.empty?
        if partial_bold_instruction?(text)
          append_note_warning!(warnings, PARTIAL_BOLD_UNMATCHED_WARNING)
          return :not_found
        end

        return nil
      end

      ambiguous_match = false
      candidates.each do |candidate|
        match = matching_text_phrase(layer["text"], candidate)
        next unless match

        if match.status == :ambiguous
          ambiguous_match = true
          next
        end

        layer["text"] = ImageProjects::InlineTextParser.bold_phrase(layer["text"], match.phrase)
        append_note_warning!(warnings, match.warning) if match.warning.present?
        return :applied
      end

      if partial_bold_instruction?(text) || ambiguous_match
        append_note_warning!(warnings, PARTIAL_BOLD_UNMATCHED_WARNING)
        return :not_found
      end

      nil
    end
    private_class_method :apply_partial_bold_note!

    def partial_bold_phrase_candidates(text)
      source = text.to_s
      chinese_bold = "(?:加粗)"
      chinese_word = "(?:这个单词|这个词|单词|词)"
      chinese_where = "(?:其中)"
      text_phrase = "[A-Za-z0-9][A-Za-z0-9 _\\-\\/&'().]+?"
      patterns = [
        Regexp.new("#{chinese_where}\\s*(.+?)\\s*(?:#{chinese_word})?\\s*#{chinese_bold}", Regexp::IGNORECASE),
        Regexp.new("(.+?)\\s*#{chinese_word}\\s*#{chinese_bold}", Regexp::IGNORECASE),
        Regexp.new("\\A\\s*(#{text_phrase})\\s*#{chinese_bold}\\s*\\z", Regexp::IGNORECASE),
        /make\s+(?!the\s+text\b|all\b)(.+?)\s+bold\b/i,
        /\bbold\s+(?!the\s+text\b|all\b)([A-Za-z0-9][A-Za-z0-9 _\-\/&'().]+?)(?:\s*[.,;]|\z)/i,
        /(?:\A|[.,;])\s*(?!all\b)([A-Za-z0-9][A-Za-z0-9 _\-\/&'().]+?)\s+bold\b/i
      ]

      candidates = []
      clauses = source.split(/[。；;,\n\r]+/)
      patterns.each do |pattern|
        candidates.concat(source.scan(pattern).flatten.compact)
        clauses.each do |clause|
          candidates.concat(clause.scan(pattern).flatten.compact)
        end
      end

      candidates.map { |candidate| clean_emphasis_phrase(candidate) }.compact_blank.uniq
    end
    private_class_method :partial_bold_phrase_candidates

    def partial_bold_instruction?(text)
      source = text.to_s.strip
      text_phrase = "[A-Za-z0-9][A-Za-z0-9 _\\-\\/&'().]+?"
      return true if source.match?(/(?:其中|这个单词|这个词|单词|词).*(?:加粗)/i)
      return true if source.match?(/make\s+(?!the\s+text\b|all\b).+\s+bold\b/i)

      source.split(/[。；;,\n\r]+/).any? do |clause|
        clause.match?(/\A\s*#{text_phrase}\s*(?:加粗)\s*\z/i) ||
          clause.match?(/\A\s*(?!all\b|the\s+text\b|text\b|make\b)#{text_phrase}\s+bold\s*\z/i) ||
          clause.match?(/\A\s*bold\s+(?!all\b|the\s+text\b|text\b)#{text_phrase}\s*\z/i)
      end
    end
    private_class_method :partial_bold_instruction?

    def clean_emphasis_phrase(value)
      phrase = value.to_s.strip
      phrase = phrase.sub(/\A["'“”‘’]+/, "").sub(/["'“”‘’.,;:，。；：\s]+\z/, "")
      phrase = phrase.sub(/\A(?:the\s+word|word)\s+/i, "")
      phrase = phrase.sub(/\A(?:其中)\s*/i, "")
      phrase = phrase.sub(/(?:这个单词|这个词|单词|词)\z/i, "").strip
      return nil if phrase.blank?
      return nil if phrase.match?(/\Amake\s+/i)
      return nil if phrase.match?(/\A(?:all|the text|text)\z/i)

      phrase
    end
    private_class_method :clean_emphasis_phrase

    def matching_text_phrase(text, candidate)
      plain = ImageProjects::InlineTextParser.plain_text(text)
      phrase = candidate.to_s
      return nil if plain.blank? || phrase.blank?

      exact_index = plain.index(phrase)
      return PartialBoldMatch.new(status: :matched, phrase: plain[exact_index, phrase.length]) if exact_index

      insensitive_index = plain.downcase.index(phrase.downcase)
      if insensitive_index
        return PartialBoldMatch.new(
          status: :matched,
          phrase: plain[insensitive_index, phrase.length]
        )
      end

      fuzzy_text_phrase(plain, phrase)
    end
    private_class_method :matching_text_phrase

    def fuzzy_text_phrase(plain, candidate)
      candidate_token = fuzzy_candidate_token(candidate)
      return nil unless candidate_token

      matches = alphanumeric_tokens(plain).select do |token|
        fuzzy_token_match?(candidate_token.downcase, token[:text].downcase)
      end

      return nil if matches.empty?
      return PartialBoldMatch.new(status: :ambiguous) if matches.size > 1

      matched_text = matches.first[:text]
      PartialBoldMatch.new(
        status: :matched,
        phrase: matched_text,
        warning: %(Partial bold note target "#{candidate}" was matched to "#{matched_text}".)
      )
    end
    private_class_method :fuzzy_text_phrase

    def fuzzy_candidate_token(candidate)
      token = candidate.to_s.strip
      return nil unless token.match?(/\A[A-Za-z0-9]+\z/)
      return nil if token.length < 5

      letter_count = token.count("A-Za-z")
      return nil if letter_count.to_f / token.length < 0.6

      token
    end
    private_class_method :fuzzy_candidate_token

    def alphanumeric_tokens(text)
      text.to_s.to_enum(:scan, /[A-Za-z0-9]+/).map do
        match = Regexp.last_match
        { text: match[0], start: match.begin(0), end: match.end(0) }
      end
    end
    private_class_method :alphanumeric_tokens

    def fuzzy_token_match?(candidate, target)
      return false if candidate == target

      length_difference = (candidate.length - target.length).abs
      return false if length_difference > maximum_fuzzy_length_difference(candidate.length, target.length)

      edit_distance(candidate, target) <= maximum_fuzzy_edit_distance(candidate.length, target.length)
    end
    private_class_method :fuzzy_token_match?

    def maximum_fuzzy_length_difference(candidate_length, target_length)
      [ candidate_length, target_length ].max >= 8 ? 2 : 1
    end
    private_class_method :maximum_fuzzy_length_difference

    def maximum_fuzzy_edit_distance(candidate_length, target_length)
      [ candidate_length, target_length ].max >= 6 ? 2 : 1
    end
    private_class_method :maximum_fuzzy_edit_distance

    def edit_distance(left, right)
      previous = (0..right.length).to_a

      left.chars.each_with_index do |left_char, left_index|
        current = [ left_index + 1 ]

        right.chars.each_with_index do |right_char, right_index|
          cost = left_char == right_char ? 0 : 1
          current << [
            current[right_index] + 1,
            previous[right_index + 1] + 1,
            previous[right_index] + cost
          ].min
        end

        previous = current
      end

      previous.last
    end
    private_class_method :edit_distance

    def append_note_warning!(warnings, message)
      return if message.blank? || warnings.nil?

      warnings << message
    end
    private_class_method :append_note_warning!

    def whole_layer_bold_note?(text)
      text.to_s.include?("加粗") || text.to_s.match?(/\bbold\b/i)
    end
    private_class_method :whole_layer_bold_note?

    def generic_letter_spacing_note?(text)
      text.include?("\u5C06\u5B57\u4F53\u95F4\u8DDD\u62C9\u5F00") ||
        text.match?(/increase\s+letter\s+spacing|spread\s+letter\s+spacing/i)
    end
    private_class_method :generic_letter_spacing_note?

    def explicit_spread_to_width_note?(text)
      normalized = text.to_s.downcase
      normalized.match?(/(?:fill|fit|span|stretch|spread)\s+(?:the\s+)?(?:text\s+)?(?:to|across|over|within)\s+(?:a\s+)?(?:target|fixed|canvas|specified)?\s*width/) ||
        normalized.match?(/(?:target|fixed|canvas)\s+width|canvas\s+ratio/) ||
        text.match?(/\u586B\u6EE1|\u94FA\u6EE1|\u76EE\u6807\u5BBD\u5EA6|\u56FA\u5B9A\u5BBD\u5EA6|\u753B\u5E03\u6BD4\u4F8B|\u5BBD\u5EA6\u6BD4\u4F8B/)
    end
    private_class_method :explicit_spread_to_width_note?

    def target_text_width_ratio(text)
      normalized = text.to_s
      if (match = normalized.match(/(?:target|fixed|canvas|text)?\s*width(?:\s*ratio)?\D*(\d+(?:\.\d+)?)\s*%/i))
        return (match[1].to_f / 100.0).clamp(0.5, 0.95)
      end

      if (match = normalized.match(/(\d+(?:\.\d+)?)\s*%\s*(?:of\s*)?(?:canvas|target|fixed|text)?\s*width/i))
        return (match[1].to_f / 100.0).clamp(0.5, 0.95)
      end

      if (match = normalized.match(/(?:canvas\s+ratio|width\s+ratio|target\s+ratio)\D*(0?\.\d+|1(?:\.0+)?)/i))
        return match[1].to_f.clamp(0.5, 0.95)
      end

      if (match = normalized.match(/(?:\u753B\u5E03|\u76EE\u6807|\u56FA\u5B9A)?\s*\u5BBD\u5EA6(?:\u6BD4\u4F8B)?\D*(\d+(?:\.\d+)?)\s*%/))
        return (match[1].to_f / 100.0).clamp(0.5, 0.95)
      end

      if (match = normalized.match(/(?:\u753B\u5E03\u6BD4\u4F8B|\u5BBD\u5EA6\u6BD4\u4F8B)\D*(0?\.\d+|1(?:\.0+)?)/))
        return match[1].to_f.clamp(0.5, 0.95)
      end

      nil
    end
    private_class_method :target_text_width_ratio

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
