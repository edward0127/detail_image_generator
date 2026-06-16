module ImageProjects
  class ExcelImporter
    Header = Struct.new(:field, :label, :index, :group_label, :group_key, :step_label, :ordinal, keyword_init: true)
    Cell = Struct.new(:header, :value, keyword_init: true)

    FIELD_ALIASES = {
      target_name: [
        "针对目标图片名", "目标图片名", "输出图片名", "targetName", "target name",
        "output name", "output image name", "filename", "file name", "编号", "图片编号", "页面", "款式"
      ],
      canvas_size: [ "图层尺寸", "画布尺寸", "背景画布大小", "canvas size", "layer size", "size" ],
      canvas_width: [ "画布宽度", "canvas width" ],
      canvas_height: [ "画布高度", "canvas height" ],
      background_color: [
        "调整图层颜色", "背景颜色", "背景色", "background", "background color", "bg color", "bg", "底色"
      ],
      source_image: [
        "对应图片", "使用图片", "源图片", "图片匹配名", "source image", "source image name",
        "main image", "imageName", "image", "图片", "主图", "图片名称", "图片文件"
      ],
      image_size: [ "调整图片大小", "图片尺寸", "image size" ],
      image_width: [ "图片宽度", "image width" ],
      image_height: [ "图片高度", "image height" ],
      image_position: [ "图片位置", "image position", "image top", "image offset" ],
      output_size: [ "统一输出尺寸", "输出尺寸", "output size", "final size" ],
      output_width: [ "输出宽度", "output width", "final width" ],
      output_height: [ "输出高度", "output height", "final height" ],
      text_content: [
        "文字内容", "文案", "标题", "副标题", "正文", "文字", "text", "text content",
        "title", "subtitle", "body", "copy"
      ],
      text_position: [ "图层位置", "文字位置", "text position", "layer position", "position" ],
      font: [ "文字字体", "字体", "font", "font name", "typeface" ],
      font_size: [ "字体尺寸", "字号", "font size", "text size" ],
      text_color: [ "文字颜色", "字体颜色", "text color", "font color", "color" ],
      notes: [ "其他说明", "说明", "备注", "notes", "instruction", "instructions", "extra notes", "要求" ],
      format: [ "输出格式", "格式", "format", "output format" ]
    }.freeze

    GENERIC_IMAGE_NAME_HEADERS = [ "图片名", "image name" ].freeze
    MAX_HEADER_SCAN_ROWS = 10

    def self.call(project, file)
      new(project, file).call
    end

    def initialize(project, file)
      @project = project
      @path = file.respond_to?(:path) ? file.path : file.to_s
    end

    def call
      sheet = first_valid_sheet
      header_row = detect_header_row(sheet)
      headers = read_headers(sheet, header_row)
      raise "The first valid worksheet does not have a recognizable field-label row." if headers.blank?

      tasks = read_tasks(sheet, headers, header_row)
      raise "No non-empty task rows were found in the worksheet." if tasks.blank?

      config = ImageProjects::DefaultConfig.build(name: project.name)
      config["projectName"] = project.name
      config["layoutMode"] = "design"
      config["tasks"] = tasks
      first_canvas = tasks.first.fetch("canvas", {})
      first_output = tasks.first.fetch("output", {})
      config["canvasDefaults"] = {
        "width" => first_canvas["width"],
        "height" => first_canvas["height"],
        "backgroundColor" => first_canvas["backgroundColor"],
        "transparent" => first_canvas["transparent"],
        "outputFormat" => first_output["format"]
      }

      project.update!(config_json: JSON.pretty_generate(config), status: "imported", last_error: nil)
      config
    rescue StandardError => error
      project.update!(status: "import_failed", last_error: error.message)
      raise
    ensure
      close_workbook
    end

    private

    attr_reader :project, :path

    def workbook
      @workbook ||= Roo::Spreadsheet.open(path)
    end

    def first_valid_sheet
      workbook.sheets.each do |sheet_name|
        sheet = workbook.sheet(sheet_name)
        return sheet if sheet.first_row.present? && sheet.last_row.present? && sheet.last_row >= sheet.first_row
      end

      raise "No valid worksheet was found."
    end

    def detect_header_row(sheet)
      last_scan_row = [ sheet.first_row + MAX_HEADER_SCAN_ROWS - 1, sheet.last_row ].min
      candidates = (sheet.first_row..last_scan_row).map do |row_number|
        values = sheet.row(row_number)
        fields = values.each_with_index.filter_map { |value, index| canonical_field(value, index: index) }
        {
          row_number: row_number,
          fields: fields,
          score: fields.size + (fields.include?(:target_name) ? 2 : 0)
        }
      end

      best = candidates.max_by { |candidate| candidate[:score] }
      raise "No recognizable Excel header row was found." if best.blank? || best[:fields].size < 2

      best[:row_number]
    end

    def read_headers(sheet, header_row)
      header_values = row_values(sheet, header_row)
      raw_group_values = row_values(sheet, header_row - 1)
      raw_step_values = row_values(sheet, header_row - 2)
      group_values = contextual_row(sheet, header_row - 1)
      step_values = contextual_row(sheet, header_row - 2)
      max_columns = [ header_values.size, raw_group_values.size, raw_step_values.size ].max

      (0...max_columns).filter_map do |index|
        group_label = context_label(group_values[index])
        step_label = context_label(step_values[index])
        field_source = field_source_for(
          index,
          header_values[index],
          raw_group_values[index],
          raw_step_values[index],
          group_label
        )
        next if field_source.blank?

        Header.new(
          field: field_source[:field],
          label: field_source[:label],
          index: index,
          group_label: group_label,
          group_key: group_key_for(step_label, group_label),
          step_label: step_label,
          ordinal: index
        )
      end
    end

    def read_tasks(sheet, headers, header_row)
      tasks = []

      ((header_row + 1)..sheet.last_row).each do |row_number|
        values = sheet.row(row_number)
        cells = row_cells(headers, values)
        next unless data_row?(cells)
        next if header_description_row?(cells)

        tasks << build_task(cells, tasks.size + 1)
      end

      tasks
    end

    def build_task(cells, position)
      warnings = []
      default_size = { "width" => 1650, "height" => 2480 }
      canvas_size = size_from_fields(cells, :canvas_size, :canvas_width, :canvas_height) || default_size
      output_size = size_from_fields(cells, :output_size, :output_width, :output_height) || canvas_size
      background = ExcelParsers.parse_color(value_for(cells, :background_color))
      warnings << background.warning if background&.warning.present?
      transparent = background&.transparent || false

      task = {
        "targetName" => target_name_for(cells, position),
        "layoutMode" => "design",
        "canvas" => {
          "width" => canvas_size["width"],
          "height" => canvas_size["height"],
          "backgroundColor" => background&.background_color || "#FAFAF0",
          "transparent" => transparent
        },
        "output" => {
          "width" => output_size["width"],
          "height" => output_size["height"],
          "format" => normalize_format(value_for(cells, :format), transparent: transparent)
        },
        "layers" => []
      }

      add_image_layers(task, cells, warnings)
      add_text_layers(task, cells, warnings)
      task["warnings"] = warnings.compact.uniq if warnings.compact.any?
      task
    end

    def add_image_layers(task, cells, warnings)
      cells_for(cells, :source_image).each do |cell|
        image_name = ExcelParsers.parse_image_reference(cell.value)
        next if image_name.blank?

        group_key = cell.header.group_key
        image_size = size_from_fields(cells, :image_size, :image_width, :image_height, group_key: group_key) ||
          { "width" => task.dig("canvas", "width"), "height" => task.dig("canvas", "height") }
        position = ExcelParsers.parse_position(scoped_value_for(cells, :image_position, group_key))
        warnings.concat(position.fetch("warnings", []))

        layer = {
          "id" => "layer#{task["layers"].size}",
          "name" => layer_name(cell, fallback: "Main Image"),
          "type" => "image",
          "imageName" => image_name,
          "width" => image_size["width"],
          "height" => image_size["height"],
          "x" => position["x"] || "center",
          "y" => position["y"] || 0,
          "fit" => image_covers_canvas?(task, image_size) ? "cover" : "contain",
          "opacity" => 1
        }
        layer["notes"] = position["notes"] if position["notes"].present?

        task["layers"] << layer
      end
    end

    def add_text_layers(task, cells, warnings)
      cells_for(cells, :text_content).each do |cell|
        text = cell.value.to_s
        next if text.strip.blank?

        group_key = cell.header.group_key
        position = ExcelParsers.parse_position(scoped_value_for(cells, :text_position, group_key))
        warnings.concat(position.fetch("warnings", []))
        font_size = ExcelParsers.parse_font_size(scoped_value_for(cells, :font_size, group_key)) || 60
        notes = scoped_value_for(cells, :notes, group_key)

        layer = {
          "id" => "layer#{task["layers"].size}",
          "name" => layer_name(cell, fallback: "Text"),
          "type" => "text",
          "text" => text,
          "font" => scoped_value_for(cells, :font, group_key).to_s.strip,
          "fontSize" => font_size,
          "color" => scoped_value_for(cells, :text_color, group_key).presence || default_text_color(task),
          "letterSpacingRatio" => 0,
          "lineHeightRatio" => default_line_height_ratio(text),
          "maxWidth" => default_text_max_width(text, task),
          "autoWrap" => default_auto_wrap_for_text(text, cell),
          "bold" => false,
          "italic" => false,
          "x" => position["x"] || "center",
          "y" => position["y"] || 200,
          "align" => "center",
          "opacity" => 1
        }

        layer["relativeTo"] = position["relativeTo"] if position["relativeTo"].present?
        layer["relativePosition"] = position["relativePosition"] if position["relativePosition"].present?
        layer["relativeOffset"] = position["relativeOffset"] if position["relativeOffset"].present?
        layer["notes"] = position["notes"] if position["notes"].present?

        ExcelParsers.apply_notes_to_text_layer!(layer, notes)
        task["layers"] << layer
      end
    end

    def close_workbook
      @workbook&.close if @workbook.respond_to?(:close)
    rescue StandardError => error
      Rails.logger.warn("Excel workbook cleanup failed: #{error.message}")
    end

    def row_values(sheet, row_number)
      return [] if row_number < sheet.first_row

      sheet.row(row_number)
    end

    def field_source_for(index, field_value, group_value, step_value, group_label)
      [
        field_value,
        group_value,
        step_value
      ].each do |value|
        field = canonical_field(value, group_label: group_label, index: index)
        return { field: field, label: value.to_s.strip } if field.present?
      end

      nil
    end

    def contextual_row(sheet, row_number)
      return [] if row_number < sheet.first_row

      current = nil
      sheet.row(row_number).map do |value|
        current = value if value.to_s.strip.present?
        current
      end
    end

    def context_label(value)
      value.to_s.strip.presence
    end

    def row_cells(headers, values)
      headers.map { |header| Cell.new(header: header, value: values[header.index]) }
    end

    def data_row?(cells)
      cells.any? { |cell| cell.value.to_s.strip.present? }
    end

    def header_description_row?(cells)
      present_values = cells.map(&:value).select { |value| value.to_s.strip.present? }
      return false if present_values.blank?

      recognized_count = present_values.count { |value| canonical_field(value).present? }
      recognized_count >= 2 && recognized_count >= (present_values.size / 2.0)
    end

    def target_name_for(cells, position)
      explicit_name = value_for(cells, :target_name).to_s.strip
      return explicit_name if explicit_name.present?

      "Task #{position}"
    end

    def size_from_fields(cells, size_field, width_field, height_field, group_key: :any)
      parsed = ExcelParsers.parse_size(value_for(cells, size_field, group_key: group_key))
      return parsed if parsed

      width = integer_value(value_for(cells, width_field, group_key: group_key))
      height = integer_value(value_for(cells, height_field, group_key: group_key))
      return nil if width.blank? || height.blank?

      { "width" => width, "height" => height }
    end

    def scoped_value_for(cells, field, group_key)
      value_for(cells, field, group_key: group_key) ||
        value_for(cells, field, group_key: nil) ||
        value_for(cells, field)
    end

    def value_for(cells, field, group_key: :any)
      matching = cells_for(cells, field)
      matching = matching.select { |cell| cell.header.group_key == group_key } unless group_key == :any || group_key.nil?
      matching = matching.select { |cell| cell.header.group_key.blank? } if group_key.nil?
      matching.find { |cell| cell.value.to_s.strip.present? }&.value
    end

    def cells_for(cells, field)
      cells.select { |cell| cell.header.field == field }
    end

    def integer_value(value)
      match = value.to_s.match(/-?\d+/)
      match ? match[0].to_i : nil
    end

    def image_covers_canvas?(task, image_size)
      image_size["width"].to_i == task.dig("canvas", "width").to_i &&
        image_size["height"].to_i == task.dig("canvas", "height").to_i
    end

    def default_text_color(task)
      canvas = task.fetch("canvas", {})
      background = canvas["backgroundColor"].to_s.downcase
      return "#F4EAD7" if canvas["transparent"] == true || background == "transparent" || full_image_background?(task)

      "#1F1F1F"
    end

    def full_image_background?(task)
      canvas_width = task.dig("canvas", "width").to_i
      canvas_height = task.dig("canvas", "height").to_i
      return false if canvas_width <= 0 || canvas_height <= 0

      Array(task["layers"]).any? do |layer|
        layer["type"].to_s == "image" &&
          layer["width"].to_i >= (canvas_width * 0.95) &&
          layer["height"].to_i >= (canvas_height * 0.95)
      end
    end

    def default_text_max_width(text, task)
      canvas_width = task.dig("canvas", "width").to_i
      return (canvas_width * 0.72).round if long_text?(text)

      canvas_width
    end

    def default_line_height_ratio(text)
      long_text?(text) ? 1.6 : 1.2
    end

    def default_auto_wrap_for_text(text, cell)
      return true if text.to_s.match?(/\r|\n/)
      return false if title_text_context?(cell) && short_single_line_text?(text)
      return true if body_text_context?(cell)

      long_text?(text)
    end

    def title_text_context?(cell)
      text_context_for(cell).match?(/\b(title|heading|headline|subtitle|subhead)\b/i)
    end

    def body_text_context?(cell)
      text_context_for(cell).match?(/\b(body|copy|paragraph|description|details?)\b/i)
    end

    def text_context_for(cell)
      [
        cell.header.label,
        cell.header.group_label,
        cell.header.step_label
      ].compact_blank.join(" ")
    end

    def short_single_line_text?(text)
      value = text.to_s
      !value.match?(/\r|\n/) && value.gsub(/\s+/, "").length <= 40
    end

    def long_text?(text)
      text.to_s.gsub(/\s+/, "").length > 60
    end

    def layer_name(cell, fallback:)
      label = cell.header.label.to_s.strip
      group = cell.header.group_label.to_s.strip
      generic_labels = FIELD_ALIASES.fetch(cell.header.field).map { |value| normalize_header(value) }

      return label if label.present? && !generic_labels.include?(normalize_header(label))
      return group if group.present?

      fallback
    end

    def canonical_field(value, group_label: nil, index: nil)
      normalized = normalize_header(value)
      return nil if normalized.blank?

      if GENERIC_IMAGE_NAME_HEADERS.map { |header| normalize_header(header) }.include?(normalized)
        return target_context?(group_label) || index.to_i.zero? ? :target_name : :source_image
      end

      FIELD_ALIASES.each do |field, aliases|
        return field if aliases.any? { |header| normalize_header(header) == normalized }
      end

      nil
    end

    def target_context?(value)
      text = value.to_s.downcase
      text.include?("目标") || text.include?("输出") || text.include?("target") || text.include?("output")
    end

    def group_key_for(step_label, group_label)
      [ step_label, group_label ].compact_blank.map { |label| normalize_header(label) }.join("|").presence
    end

    def normalize_header(value)
      text = value.to_s.strip
      text = text.unicode_normalize(:nfkc) if text.respond_to?(:unicode_normalize)
      text.downcase.gsub(/[\s_\-:：\/\\\(\)\[\]（）]+/, "")
    end

    def normalize_format(value, transparent:)
      format = value.to_s.strip.downcase.delete_prefix(".")
      return "png" if format == "png"
      return "webp" if format == "webp"
      return "jpg" if %w[jpg jpeg].include?(format)

      transparent ? "png" : "jpg"
    end
  end
end
