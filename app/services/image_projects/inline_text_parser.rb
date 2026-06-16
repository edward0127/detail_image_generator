module ImageProjects
  module InlineTextParser
    MARKERS = [
      [ "***", { bold: true, italic: true } ],
      [ "**", { bold: true, italic: false } ],
      [ "*", { bold: false, italic: true } ]
    ].freeze

    module_function

    def parse(text)
      source = text.to_s
      runs = []
      buffer = +""
      index = 0

      while index < source.length
        marker, style = marker_at(source, index)

        unless marker
          buffer << source[index]
          index += 1
          next
        end

        closing_index = source.index(marker, index + marker.length)
        if closing_index && closing_index > index + marker.length
          append_run(runs, buffer, bold: false, italic: false)
          buffer = +""
          append_run(
            runs,
            source[(index + marker.length)...closing_index],
            bold: style[:bold],
            italic: style[:italic]
          )
          index = closing_index + marker.length
        else
          buffer << marker
          index += marker.length
        end
      end

      append_run(runs, buffer, bold: false, italic: false)
      runs.presence || [ { text: "", bold: false, italic: false } ]
    end

    def plain_text(text)
      parse(text).map { |run| run[:text] }.join
    end

    def markup?(text)
      parse(text).any? { |run| run[:bold] || run[:italic] }
    end

    def bold_phrase(text, phrase)
      source = text.to_s
      target = phrase.to_s
      return source if source.blank? || target.blank?
      return source if markup?(source) && marked_phrase?(source, target)

      ranges = plain_text_run_ranges(source)
      plain = plain_text(source)
      match_index = plain.index(target) || plain.downcase.index(target.downcase)
      return source unless match_index

      match_end = match_index + target.length
      source_start = nil
      source_end = nil

      ranges.each do |range|
        next if range[:plain_end] <= match_index || range[:plain_start] >= match_end

        source_start ||= range[:source_start] + [ match_index - range[:plain_start], 0 ].max
        source_end = range[:source_start] + [ match_end - range[:plain_start], range[:source_end] - range[:source_start] ].min
      end

      return source unless source_start && source_end && source_start < source_end

      "#{source[0...source_start]}**#{source[source_start...source_end]}**#{source[source_end..]}"
    end

    def phrase_marked_bold?(text, phrase)
      marked_phrase?(text, phrase)
    end

    def plain_text_run_ranges(text)
      source = text.to_s
      ranges = []
      plain_index = 0
      index = 0

      while index < source.length
        marker, = marker_at(source, index)

        unless marker
          ranges << {
            plain_start: plain_index,
            plain_end: plain_index + 1,
            source_start: index,
            source_end: index + 1
          }
          plain_index += 1
          index += 1
          next
        end

        closing_index = source.index(marker, index + marker.length)
        if closing_index && closing_index > index + marker.length
          content_start = index + marker.length
          content_end = closing_index
          content = source[content_start...content_end]
          ranges << {
            plain_start: plain_index,
            plain_end: plain_index + content.length,
            source_start: content_start,
            source_end: content_end
          }
          plain_index += content.length
          index = closing_index + marker.length
        else
          marker.length.times do |offset|
            ranges << {
              plain_start: plain_index,
              plain_end: plain_index + 1,
              source_start: index + offset,
              source_end: index + offset + 1
            }
            plain_index += 1
          end
          index += marker.length
        end
      end

      ranges
    end

    def append_run(runs, text, bold:, italic:)
      return if text.blank?

      if runs.last && runs.last[:bold] == bold && runs.last[:italic] == italic
        runs.last[:text] << text
      else
        runs << { text: text, bold: bold, italic: italic }
      end
    end
    private_class_method :append_run

    def marker_at(source, index)
      MARKERS.find { |marker, _style| source[index, marker.length] == marker }
    end
    private_class_method :marker_at

    def marked_phrase?(text, phrase)
      target = phrase.to_s.downcase
      return false if target.blank?

      parse(text).any? do |run|
        run[:bold] && run[:text].downcase.include?(target)
      end
    end
    private_class_method :marked_phrase?
  end
end
