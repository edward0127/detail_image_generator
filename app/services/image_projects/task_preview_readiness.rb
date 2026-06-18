module ImageProjects
  class TaskPreviewReadiness
    def self.call(project, task)
      new(project).call(task)
    end

    def initialize(project)
      @project = project
      @image_matcher = ImageMatcher.new(project)
    end

    def call(task)
      layers = Array(task && task["layers"])
      if layers.empty?
        return {
          ready: false,
          message: "Add at least one layer before previewing.",
          alert: "Please import Excel or add layers before previewing."
        }
      end

      unless layers.any? { |layer| renderable_layer?(layer) }
        return {
          ready: false,
          message: "Add at least one renderable text or image layer before previewing.",
          alert: "Please import Excel or add renderable layers before previewing."
        }
      end

      missing_images = missing_required_images_for_task(task)
      if missing_images.any?
        return {
          ready: false,
          message: "Upload the required source images before previewing: #{missing_images.join(', ')}.",
          alert: "Please upload the required source images before previewing."
        }
      end

      { ready: true, message: nil, alert: nil }
    end

    private

    attr_reader :project, :image_matcher

    def renderable_layer?(layer)
      case layer["type"].to_s
      when "text"
        ImageProjects::InlineTextParser.plain_text(layer["text"]).strip.present?
      when "image"
        layer["imageName"].to_s.strip.present?
      else
        false
      end
    end

    def missing_required_images_for_task(task)
      Array(task && task["layers"]).filter_map do |layer|
        next unless layer["type"].to_s == "image"

        image_name = layer["imageName"].to_s.strip
        next if image_name.blank?

        match = image_matcher.match(image_name)
        next if match.found? && match.asset.file.attached?

        image_name
      end.uniq
    end
  end
end
