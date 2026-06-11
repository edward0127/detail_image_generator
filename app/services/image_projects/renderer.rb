require "base64"
require "erb"
require "fileutils"
require "securerandom"

module ImageProjects
  class Renderer
    RenderResult = Struct.new(:path, :filename, :format, :width, :height, :warnings, :errors, keyword_init: true)

    DEFAULT_RELATIVE_GAP = 24
    DESIGN_IMAGE_WIDTH_RATIO = 0.6
    DESIGN_BODY_WIDTH_RATIO = 0.72
    DESIGN_BODY_LINE_HEIGHT_RATIO = 1.6
    FALLBACK_FONT_FAMILY = 'Arial, "Microsoft YaHei", "Microsoft JhengHei", "SimSun", "Noto Sans CJK SC", "Noto Sans CJK TC", sans-serif'
    BROWSER_PATHS = [
      ENV["CHROME_BIN"],
      ENV["BROWSER_PATH"],
      "/usr/bin/chromium",
      "/usr/bin/chromium-browser",
      "/usr/bin/google-chrome",
      "C:/Program Files/Google/Chrome/Application/chrome.exe",
      "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
      "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
      "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
    ].compact.freeze

    def initialize(project)
      @project = project
      @image_matcher = ImageMatcher.new(project)
      @font_matcher = FontMatcher.new(project)
    end

    def render_preview(task_config, scale: 0.5)
      render_task(task_config, scale: scale, preview: true)
    end

    def render_final(task_config)
      render_task(task_config, scale: 1.0, preview: false)
    end

    def render_project(project)
      project.tasks.map { |task| render_final(task) }
    end

    def self.browser_path
      BROWSER_PATHS.find { |path| path.present? && File.exist?(path) }
    end

    private

    attr_reader :project, :image_matcher, :font_matcher

    def render_task(task_config, scale:, preview:)
      browser = nil
      warnings = Array(task_config["warnings"]).dup
      errors = []
      dimensions = dimensions_for(task_config, scale: scale, preview: preview)
      format = output_format(task_config)
      screenshot_format = format == "jpg" ? "jpeg" : format
      html = build_html(task_config, dimensions, format, warnings, errors)
      output_path = output_path_for(task_config["targetName"], format)

      browser = Ferrum::Browser.new(
        browser_path: self.class.browser_path,
        window_size: [ dimensions[:target_width], dimensions[:target_height] ],
        timeout: 20,
        process_timeout: 20,
        browser_options: {
          "no-sandbox" => nil,
          "disable-dev-shm-usage" => nil,
          "disable-gpu" => nil,
          "hide-scrollbars" => nil
        }
      )
      browser.content = html
      wait_for_assets(browser)
      browser.resize(width: dimensions[:target_width], height: dimensions[:target_height])
      browser.screenshot(
        path: output_path,
        selector: "#frame",
        format: screenshot_format,
        quality: screenshot_format == "png" ? nil : 95,
        background_color: transparent_png?(task_config, format) ? Ferrum::RGBA.new(0, 0, 0, 0.0) : nil
      )

      RenderResult.new(
        path: output_path,
        filename: "#{safe_filename(task_config["targetName"])}.#{format}",
        format: format,
        width: dimensions[:target_width],
        height: dimensions[:target_height],
        warnings: warnings.compact,
        errors: errors.compact
      )
    rescue StandardError => error
      ImageProjects::TempfileManager.delete(output_path) if output_path.present?
      errors << "Renderer failed for '#{task_config["targetName"].presence || "Untitled task"}': #{error.message}"
      RenderResult.new(
        path: nil,
        filename: "#{safe_filename(task_config["targetName"])}.#{format || "png"}",
        format: format || "png",
        width: dimensions&.fetch(:target_width, nil),
        height: dimensions&.fetch(:target_height, nil),
        warnings: warnings.compact,
        errors: errors.compact
      )
    ensure
      safely_quit_browser(browser)
    end

    def build_html(task_config, dimensions, format, warnings, errors)
      canvas = task_config.fetch("canvas", {})
      layers = prepared_layers_for_render(task_config, dimensions)
      layers = resolve_relative_layers(layers)
      background = canvas_background(canvas)
      frame_background = frame_background(canvas, format)
      font_faces = []
      layer_html = layers.map do |layer|
        render_layer(layer, task_config, dimensions, font_faces, warnings, errors)
      end.join("\n")

      <<~HTML
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <style>
              #{font_faces.uniq.join("\n")}
              * { box-sizing: border-box; }
              html, body {
                margin: 0;
                width: #{dimensions[:target_width]}px;
                height: #{dimensions[:target_height]}px;
                overflow: hidden;
                background: #{frame_background};
              }
              #frame {
                width: #{dimensions[:target_width]}px;
                height: #{dimensions[:target_height]}px;
                overflow: hidden;
                position: relative;
                background: #{frame_background};
              }
              #canvas {
                position: relative;
                width: #{dimensions[:canvas_width]}px;
                height: #{dimensions[:canvas_height]}px;
                transform-origin: top left;
                transform: scale(#{dimensions[:scale_x]}, #{dimensions[:scale_y]});
                background: #{background};
              }
              .layer {
                position: absolute;
              }
            </style>
          </head>
          <body>
            <div id="frame">
              <div id="canvas">
                #{layer_html}
              </div>
            </div>
          </body>
        </html>
      HTML
    end

    def prepared_layers_for_render(task_config, dimensions)
      layers = Array(task_config["layers"]).map(&:deep_dup)
      return layers unless design_layout?(task_config)

      apply_design_image_scale!(layers, dimensions)
      apply_design_text_layout!(layers, dimensions)
      layers
    end

    def apply_design_image_scale!(layers, dimensions)
      return unless ecommerce_detail_layout?(layers, dimensions)

      target_width = (dimensions[:canvas_width] * DESIGN_IMAGE_WIDTH_RATIO).round
      layers.each do |layer|
        next unless design_image_scale_candidate?(layer, dimensions)

        width = number(layer["width"], 0)
        height = number(layer["height"], 0)
        next if width <= 0 || height <= 0

        scale = target_width.to_f / width
        next if scale <= 1.05

        layer["width"] = target_width
        layer["height"] = (height * scale).round
      end
    end

    def apply_design_text_layout!(layers, dimensions)
      return unless ecommerce_detail_layout?(layers, dimensions)

      body_max_width = (dimensions[:canvas_width] * DESIGN_BODY_WIDTH_RATIO).round
      layers.each do |layer|
        next unless layer["type"].to_s == "text"
        next unless long_text?(layer["text"])

        current_max_width = number(layer["maxWidth"], 0)
        layer["maxWidth"] = body_max_width if current_max_width <= 0 || current_max_width > body_max_width
        layer["lineHeightRatio"] = DESIGN_BODY_LINE_HEIGHT_RATIO if number(layer["lineHeightRatio"], 0) < DESIGN_BODY_LINE_HEIGHT_RATIO
        layer["align"] = "center" if layer["align"].blank?
        layer["autoWrap"] = true unless layer.key?("autoWrap")
      end
    end

    def ecommerce_detail_layout?(layers, dimensions)
      dimensions[:canvas_width].between?(1400, 1900) &&
        dimensions[:canvas_height].between?(2200, 2700) &&
        layers.count { |layer| layer["type"].to_s == "text" } >= 3
    end

    def design_image_scale_candidate?(layer, dimensions)
      return false unless layer["type"].to_s == "image"
      return false unless layer["x"].to_s == "center"

      width = number(layer["width"], 0)
      height = number(layer["height"], 0)
      width.between?(dimensions[:canvas_width] * 0.25, dimensions[:canvas_width] * 0.45) &&
        height.between?(dimensions[:canvas_width] * 0.25, dimensions[:canvas_height] * 0.35)
    end

    def design_layout?(task_config)
      (task_config["layoutMode"].presence || project.config_hash["layoutMode"]).to_s == "design"
    end

    def render_layer(layer, task_config, dimensions, font_faces, warnings, errors)
      case layer["type"].to_s
      when "image"
        render_image_layer(layer, task_config, warnings, errors)
      when "text"
        render_text_layer(layer, task_config, font_faces, warnings, dimensions)
      else
        warnings << "Layer '#{layer["name"].presence || layer["id"]}' has unsupported type '#{layer["type"]}' and was skipped."
        ""
      end
    end

    def render_image_layer(layer, task_config, warnings, errors)
      match = image_matcher.match(layer["imageName"])
      unless match.found?
        errors << missing_image_error(task_config, layer)
        return ""
      end
      warnings << match.warning if match.warning.present?
      unless match.asset.file.attached?
        errors << "Task #{task_label(task_config)} could not be generated because source image \"#{layer["imageName"]}\" matched \"#{match.asset.name}\", but the uploaded asset has no attached file."
        return ""
      end

      width = number(layer["width"], 100)
      height = number(layer["height"], 100)
      fit = layer["fit"].to_s == "stretch" ? "fill" : %w[contain cover].include?(layer["fit"].to_s) ? layer["fit"] : "contain"
      style = [
        position_style(layer, width, height),
        "width: #{width}px",
        "height: #{height}px",
        "opacity: #{number(layer["opacity"], 1)}",
        "object-fit: #{fit}",
        "display: block"
      ].join("; ")

      %(<img class="layer" alt="" src="#{html_attr(data_uri(match.asset.file))}" style="#{html_attr(style)}">)
    end

    def missing_image_error(task_config, layer)
      "Task #{task_label(task_config)} could not be generated because source image \"#{layer["imageName"]}\" was not found. Upload a matching file or set an image alias."
    end

    def render_text_layer(layer, task_config, font_faces, warnings, dimensions)
      font_family = font_family_for(layer, font_faces, warnings)
      font_size = number(layer["fontSize"], 60)
      max_width = number(layer["maxWidth"], dimensions[:canvas_width])
      letter_spacing = text_letter_spacing(layer, font_size, max_width, dimensions)
      line_height = number(layer["lineHeightRatio"], 1.2)
      white_space = truthy?(layer["autoWrap"]) ? "pre-wrap" : "pre"
      font_weight = truthy?(layer["bold"]) ? "700" : "400"
      font_style = truthy?(layer["italic"]) ? "italic" : "normal"
      style = [
        position_style(layer, max_width, font_size * line_height),
        "max-width: #{max_width}px",
        "font-family: #{font_family}",
        "font-size: #{font_size}px",
        "color: #{layer["color"].presence || default_text_color(task_config)}",
        "letter-spacing: #{letter_spacing}px",
        "line-height: #{line_height}",
        "font-weight: #{font_weight}",
        "font-style: #{font_style}",
        "text-align: #{text_align(layer["align"])}",
        "white-space: #{white_space}",
        "overflow-wrap: break-word",
        "opacity: #{number(layer["opacity"], 1)}"
      ].join("; ")

      %(<div class="layer" style="#{html_attr(style)}">#{ERB::Util.html_escape(layer["text"].to_s)}</div>)
    end

    def text_letter_spacing(layer, font_size, max_width, dimensions)
      fallback = font_size * number(layer["letterSpacingRatio"], 0)
      return fallback unless layer["letterSpacingMode"].to_s == "spread"

      target_ratio = number(layer["targetTextWidthRatio"], 0.78).clamp(0.5, 0.95)
      target_width = dimensions[:canvas_width] * target_ratio
      target_width = [ target_width, max_width ].min if max_width.positive?
      base_width, gaps = estimated_single_line_text_metrics(layer["text"].to_s, font_size)
      return fallback if base_width <= 0 || gaps <= 0

      spacing = (target_width - base_width) / gaps
      return fallback if spacing <= fallback

      [ spacing, font_size * 1.25 ].min
    end

    def estimated_single_line_text_metrics(text, font_size)
      line = text.to_s.split(/\r?\n/).max_by(&:length).to_s
      chars = line.each_char.to_a
      return [ 0, 0 ] if chars.empty?

      width = chars.sum { |char| estimated_character_width(char, font_size) }
      [ width, [ chars.size - 1, 0 ].max ]
    end

    def font_family_for(layer, font_faces, warnings)
      match = font_matcher.match(layer["font"])
      warnings << match.warning if match.warning.present?
      return FALLBACK_FONT_FAMILY unless match.found? && match.asset.file.attached?

      family = "uploaded_font_#{match.asset.id}"
      font_faces << <<~CSS
        @font-face {
          font-family: "#{family}";
          src: url("#{data_uri(match.asset.file)}") format("#{font_format(match.asset.name)}");
          font-display: block;
        }
      CSS
      %("#{family}", #{FALLBACK_FONT_FAMILY})
    end

    def task_label(task_config)
      task_config["targetName"].presence || "Untitled task"
    end

    def dimensions_for(task_config, scale:, preview:)
      canvas = task_config.fetch("canvas", {})
      output = task_config.fetch("output", {})
      canvas_width = number(canvas["width"], 1650).to_i
      canvas_height = number(canvas["height"], 2480).to_i
      final_width = number(output["width"], canvas_width).to_i
      final_height = number(output["height"], canvas_height).to_i
      target_width = preview ? (final_width * scale).round : final_width
      target_height = preview ? (final_height * scale).round : final_height

      {
        canvas_width: canvas_width,
        canvas_height: canvas_height,
        target_width: [ target_width, 1 ].max,
        target_height: [ target_height, 1 ].max,
        scale_x: [ target_width, 1 ].max.to_f / canvas_width,
        scale_y: [ target_height, 1 ].max.to_f / canvas_height
      }
    end

    def position_style(layer, width, height)
      x = layer["x"]
      y = layer["y"]
      transforms = []
      rules = []

      if x.to_s == "center"
        rules << "left: 50%"
        transforms << "translateX(-50%)"
      else
        rules << "left: #{number(x, 0)}px"
      end

      if y.to_s == "center"
        rules << "top: 50%"
        transforms << "translateY(-50%)"
      else
        rules << "top: #{number(y, 0)}px"
      end

      rules << "width: #{width}px" if width
      rules << "height: #{height}px" if height
      rules << "transform: #{transforms.join(" ")}" if transforms.any?
      rules.join("; ")
    end

    def resolve_relative_layers(layers)
      resolved = []
      by_id = {}

      layers.each do |layer|
        copy = layer.deep_dup
        if copy["relativeTo"].present? && by_id[copy["relativeTo"]]
          reference = by_id[copy["relativeTo"]]
          copy["y"] = estimated_bottom(reference) + relative_offset(copy)
          copy["x"] ||= "center"
        end
        resolved << copy
        by_id[copy["id"]] = copy if copy["id"].present?
      end

      resolved
    end

    def estimated_bottom(layer)
      top = layer["y"].to_s == "center" ? 0 : number(layer["y"], 0)
      top + estimated_height(layer)
    end

    def estimated_height(layer)
      return number(layer["height"], 0) unless layer["type"].to_s == "text"

      font_size = number(layer["fontSize"], 60)
      line_height = number(layer["lineHeightRatio"], 1.2)
      line_count = estimated_line_count(layer, font_size)
      line_count * font_size * line_height
    end

    def estimated_line_count(layer, font_size)
      text = layer["text"].to_s
      return [ text.lines.size, 1 ].max unless truthy?(layer["autoWrap"])

      max_width = number(layer["maxWidth"], 0)
      return [ text.lines.size, 1 ].max if max_width <= 0

      letter_spacing = font_size * number(layer["letterSpacingRatio"], 0)
      text.split(/\r?\n/, -1).sum do |paragraph|
        estimate_wrapped_lines(paragraph, max_width, font_size, letter_spacing)
      end.clamp(1, Float::INFINITY)
    end

    def estimate_wrapped_lines(text, max_width, font_size, letter_spacing)
      return 1 if text.blank?

      lines = 1
      current_width = 0.0
      text.each_char do |char|
        char_width = estimated_character_width(char, font_size) + letter_spacing
        if current_width.positive? && current_width + char_width > max_width
          lines += 1
          current_width = char_width
        else
          current_width += char_width
        end
      end
      lines
    end

    def estimated_character_width(char, font_size)
      return font_size * 0.35 if char.match?(/\s/)
      return font_size if char.match?(/\p{Han}|\p{Hiragana}|\p{Katakana}/)

      font_size * 0.58
    end

    def long_text?(text)
      text.to_s.gsub(/\s+/, "").length > 60
    end

    def relative_offset(layer)
      return number(layer["relativeOffset"], 0) if layer.key?("relativeOffset") && layer["relativeOffset"].present?

      DEFAULT_RELATIVE_GAP
    end

    def output_format(task_config)
      format = task_config.dig("output", "format").to_s.downcase
      return "png" if format == "png"
      return "webp" if format == "webp"

      "jpg"
    end

    def canvas_background(canvas)
      return "transparent" if truthy?(canvas["transparent"]) || canvas["backgroundColor"].to_s.downcase == "transparent"

      canvas["backgroundColor"].presence || "#FFFFFF"
    end

    def frame_background(canvas, format)
      return "#FFFFFF" if format == "jpg" && (truthy?(canvas["transparent"]) || canvas["backgroundColor"].to_s.downcase == "transparent")

      canvas_background(canvas)
    end

    def transparent_png?(task_config, format)
      canvas = task_config.fetch("canvas", {})
      format == "png" && (truthy?(canvas["transparent"]) || canvas["backgroundColor"].to_s.downcase == "transparent")
    end

    def wait_for_assets(browser)
      browser.evaluate_async(<<~JS, 20)
        const done = arguments[0];
        const imagePromises = Array.from(document.images).map((image) => {
          if (image.complete) { return true; }
          return new Promise((resolve) => {
            image.onload = resolve;
            image.onerror = resolve;
          });
        });
        Promise.all(imagePromises)
          .then(() => document.fonts ? document.fonts.ready : true)
          .then(() => requestAnimationFrame(() => done(true)))
          .catch(() => done(true));
      JS
    end

    def data_uri(attachment)
      blob = attachment.blob
      content_type = blob.content_type.presence || "application/octet-stream"
      bytes = +"".b
      blob.download { |chunk| bytes << chunk }
      "data:#{content_type};base64,#{Base64.strict_encode64(bytes)}"
    end

    def html_attr(value)
      ERB::Util.html_escape(value.to_s)
    end

    def default_text_color(task_config)
      canvas = task_config.fetch("canvas", {})
      background = canvas["backgroundColor"].to_s.downcase
      return "#F4EAD7" if truthy?(canvas["transparent"]) || background == "transparent" || full_image_background?(task_config)

      "#1F1F1F"
    end

    def full_image_background?(task_config)
      canvas = task_config.fetch("canvas", {})
      canvas_width = number(canvas["width"], 0)
      canvas_height = number(canvas["height"], 0)
      return false if canvas_width <= 0 || canvas_height <= 0

      Array(task_config["layers"]).any? do |layer|
        layer["type"].to_s == "image" &&
          number(layer["width"], 0) >= canvas_width * 0.95 &&
          number(layer["height"], 0) >= canvas_height * 0.95
      end
    end

    def font_format(name)
      case File.extname(name.to_s).downcase
      when ".otf"
        "opentype"
      else
        "truetype"
      end
    end

    def text_align(value)
      %w[left center right].include?(value.to_s) ? value.to_s : "center"
    end

    def number(value, fallback)
      return fallback if value.nil?
      return value if value.is_a?(Numeric)

      parsed = value.to_s.match(/-?\d+(?:\.\d+)?/)
      parsed ? parsed[0].to_f : fallback
    end

    def truthy?(value)
      value == true || value.to_s == "true" || value.to_s == "1"
    end

    def safe_filename(value)
      value.to_s.strip.presence&.gsub(/[^\p{Alnum}\.\-_]+/, "_") || "image-#{SecureRandom.hex(4)}"
    end

    def output_path_for(target_name, format)
      ImageProjects::TempfileManager.path(prefix: safe_filename(target_name), extension: ".#{format}", subdir: "renders")
    end

    def safely_quit_browser(browser)
      browser&.quit
    rescue StandardError => error
      Rails.logger.warn("Browser cleanup failed: #{error.message}")
    end
  end
end
