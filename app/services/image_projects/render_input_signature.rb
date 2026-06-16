require "digest"
require "json"

module ImageProjects
  class RenderInputSignature
    VERSION = "render-input-v1"
    PREVIEW_MODE = "preview"
    FINAL_ZIP_MODE = "final_zip"

    def self.preview_task(project, task_index)
      new(project).preview_task(task_index)
    end

    def self.full_zip(project)
      new(project).full_zip
    end

    def self.canonical_json(value)
      JSON.generate(canonicalize(value))
    end

    def self.canonicalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          original_key = value.key?(key) ? key : key.to_sym
          result[key] = canonicalize(value[original_key])
        end
      when Array
        value.map { |item| canonicalize(item) }
      else
        value
      end
    end

    def initialize(project)
      @project = project
      @image_matcher = ImageMatcher.new(project)
      @font_matcher = FontMatcher.new(project)
    end

    def preview_task(task_index)
      task = project.tasks[task_index]
      raise "No task exists at index #{task_index}." if task.blank?

      digest_for(
        "version" => VERSION,
        "mode" => PREVIEW_MODE,
        "tasks" => [ task_payload(task, task_index) ]
      )
    end

    def full_zip
      digest_for(
        "version" => VERSION,
        "mode" => FINAL_ZIP_MODE,
        "tasks" => project.tasks.map.with_index { |task, index| task_payload(task, index) }
      )
    end

    private

    attr_reader :project, :image_matcher, :font_matcher

    def digest_for(payload)
      Digest::SHA256.hexdigest(self.class.canonical_json(payload))
    end

    def task_payload(task, index)
      {
        "index" => index,
        "task_config" => task,
        "effective_output" => effective_output_for(task),
        "image_dependencies" => image_dependencies_for(task),
        "font_dependencies" => font_dependencies_for(task)
      }
    end

    def effective_output_for(task)
      canvas = task.fetch("canvas", {})
      output = task.fetch("output", {})
      canvas_width = number(canvas["width"], 1650).to_i
      canvas_height = number(canvas["height"], 2480).to_i

      {
        "width" => number(output["width"], canvas_width).to_i,
        "height" => number(output["height"], canvas_height).to_i,
        "format" => output_format(task)
      }
    end

    def image_dependencies_for(task)
      Array(task["layers"]).map.with_index.filter_map do |layer, index|
        next unless layer["type"].to_s == "image"

        reference = layer["imageName"].to_s.strip
        next if reference.blank?

        match = image_matcher.match(reference)
        dependency = layer_dependency_base(layer, index, reference)

        if match.found?
          dependency.merge(
            "status" => match.asset.file.attached? ? "matched" : "matched_file_missing",
            "warning" => match.warning,
            "error" => match.asset.file.attached? ? nil : match.error,
            "asset" => asset_payload(match.asset)
          )
        else
          dependency.merge(
            "status" => "missing",
            "error" => match.error,
            "asset" => nil
          )
        end
      end
    end

    def font_dependencies_for(task)
      Array(task["layers"]).map.with_index.filter_map do |layer, index|
        next unless layer["type"].to_s == "text"

        reference = layer["font"].to_s.strip
        match = font_matcher.match(reference)
        dependency = layer_dependency_base(layer, index, reference)

        if match.found?
          attached = match.asset.file.attached?
          dependency.merge(
            "status" => attached && !match.fallback? ? "matched" : "matched_file_missing",
            "warning" => match.warning,
            "fallback" => match.fallback?,
            "asset" => asset_payload(match.asset)
          )
        else
          dependency.merge(
            "status" => reference.present? ? "missing_fallback" : "browser_fallback",
            "warning" => match.warning,
            "fallback" => true,
            "asset" => nil
          )
        end
      end
    end

    def layer_dependency_base(layer, index, reference)
      {
        "layer_index" => index,
        "layer_id" => layer["id"].to_s,
        "reference" => reference
      }
    end

    def asset_payload(asset)
      attachment = asset.file if asset.respond_to?(:file)
      blob = attachment&.attached? ? attachment.blob : nil

      {
        "model" => asset.class.name,
        "scope" => asset_scope(asset),
        "id" => asset.id,
        "name" => asset.name.to_s,
        "normalized_name" => asset.respond_to?(:normalized_name) ? asset.normalized_name.to_s : nil,
        "alias_name" => asset.respond_to?(:alias_name) ? asset.alias_name.to_s : nil,
        "match_name" => asset.respond_to?(:match_name) ? asset.match_name.to_s : nil,
        "attached" => blob.present?,
        "blob" => blob_payload(blob)
      }
    end

    def blob_payload(blob)
      return nil unless blob

      {
        "id" => blob.id,
        "checksum" => blob.checksum,
        "filename" => blob.filename.to_s,
        "byte_size" => blob.byte_size
      }
    end

    def asset_scope(asset)
      case asset
      when GlobalFontAsset
        "global"
      when FontAsset, ImageAsset
        "project"
      else
        "unknown"
      end
    end

    def output_format(task)
      format = task.dig("output", "format").to_s.downcase
      return "png" if format == "png"
      return "webp" if format == "webp"

      "jpg"
    end

    def number(value, fallback)
      return fallback if value.nil?
      return value if value.is_a?(Numeric)

      parsed = value.to_s.match(/-?\d+(?:\.\d+)?/)
      parsed ? parsed[0].to_f : fallback
    end
  end
end
