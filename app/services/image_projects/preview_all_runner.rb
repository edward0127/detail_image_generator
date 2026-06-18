module ImageProjects
  class PreviewAllRunner
    PREVIEW_SCALE = 0.5

    Result = Struct.new(
      :total_count,
      :previewable_count,
      :regenerated_count,
      :reused_count,
      :skipped_count,
      :failed_count,
      :warnings,
      :errors,
      :skipped_tasks,
      :failed_tasks,
      keyword_init: true
    ) do
      def no_previewable?
        previewable_count.to_i.zero?
      end

      def no_previewable_message
        detail = skipped_tasks.find { |task| task[:alert].present? }&.fetch(:alert)
        return "No previewable tasks found. #{detail}" if detail.present?

        "No previewable tasks found. Import Excel or add at least one previewable task."
      end

      def summary_message
        return no_previewable_message if no_previewable?

        if regenerated_count.to_i.zero? && reused_count.to_i.positive? && skipped_count.to_i.zero? && failed_count.to_i.zero?
          return "All previews are already up to date."
        end

        parts = []
        parts << count_phrase(regenerated_count, "Generated", "preview") if regenerated_count.to_i.positive?
        parts << count_phrase(reused_count, "reused", "cached preview") if reused_count.to_i.positive?
        parts << count_phrase(skipped_count, "skipped", "invalid task") if skipped_count.to_i.positive?
        parts << count_phrase(failed_count, "failed", "task") if failed_count.to_i.positive?

        sentence = parts.presence&.join(", ") || "No previews were generated"
        "#{sentence[0].upcase}#{sentence[1..]}."
      end

      private

      def count_phrase(count, verb, noun)
        "#{verb} #{count} #{pluralize_word(count, noun)}"
      end

      def pluralize_word(count, noun)
        return noun if count.to_i == 1
        return "cached previews" if noun == "cached preview"

        "#{noun}s"
      end
    end

    def self.call(project, renderer: nil)
      new(project, renderer: renderer).call
    end

    def initialize(project, renderer: nil)
      @project = project
      @renderer = renderer
    end

    def call
      preload_dependencies

      result = new_result
      signature_builder = RenderInputSignature.new(project)
      readiness_checker = TaskPreviewReadiness.new(project)
      previews_by_key = current_previews_by_key
      tasks_to_render = []

      project.tasks.each_with_index do |task, index|
        queue_task(task, index, result, signature_builder, readiness_checker, previews_by_key, tasks_to_render)
      end

      if tasks_to_render.any?
        with_renderer_batch do
          tasks_to_render.each { |entry| render_task_entry(entry, result) }
        end
      end

      result
    end

    private

    attr_reader :project

    def new_result
      Result.new(
        total_count: project.tasks.size,
        previewable_count: 0,
        regenerated_count: 0,
        reused_count: 0,
        skipped_count: 0,
        failed_count: 0,
        warnings: [],
        errors: [],
        skipped_tasks: [],
        failed_tasks: []
      )
    end

    def queue_task(task, index, result, signature_builder, readiness_checker, previews_by_key, tasks_to_render)
      task_name = task_display_name(task, index)
      readiness = readiness_checker.call(task)

      unless readiness[:ready]
        result.skipped_count += 1
        result.skipped_tasks << {
          index: index,
          task_name: task_name,
          message: readiness[:message],
          alert: readiness[:alert]
        }
        return
      end

      result.previewable_count += 1
      input_signature = signature_builder.preview_task(index)

      if previews_by_key[preview_key(index, task_name, input_signature)]
        result.reused_count += 1
        return
      end

      tasks_to_render << {
        task: task,
        index: index,
        task_name: task_name,
        input_signature: input_signature
      }
    rescue StandardError => error
      result.failed_count += 1
      result.failed_tasks << { index: index, task_name: task_name, errors: [ error.message ] }
      result.errors << task_message(index, task_name, error.message)
    end

    def render_task_entry(entry, result)
      render_and_attach_task(
        entry[:task],
        entry[:index],
        entry[:task_name],
        entry[:input_signature],
        result
      )
    rescue StandardError => error
      result.failed_count += 1
      result.failed_tasks << { index: entry[:index], task_name: entry[:task_name], errors: [ error.message ] }
      result.errors << task_message(entry[:index], entry[:task_name], error.message)
    end

    def render_and_attach_task(task, index, task_name, input_signature, result)
      render_result = renderer.render_preview(task, scale: PREVIEW_SCALE)
      collect_render_messages(render_result, index, task_name, result)

      unless render_result.path.present? && File.exist?(render_result.path)
        result.failed_count += 1
        errors = render_result.errors.presence || [ "Renderer did not produce a preview file." ]
        result.failed_tasks << { index: index, task_name: task_name, errors: errors }
        return
      end

      attach_preview_result!(render_result, task, index, input_signature)
      result.regenerated_count += 1
    ensure
      ImageProjects::TempfileManager.delete(render_result.path) if render_result&.path.present? && File.exist?(render_result.path)
    end

    def collect_render_messages(render_result, index, task_name, result)
      Array(render_result.warnings).each do |warning|
        result.warnings << task_message(index, task_name, warning)
      end

      Array(render_result.errors).each do |error|
        result.errors << task_message(index, task_name, error)
      end
    end

    def attach_preview_result!(render_result, task, index, input_signature)
      File.open(render_result.path, "rb") do |file|
        preview = project.task_previews.find_or_initialize_by(
          task_index: index,
          input_signature: input_signature
        )
        preview.assign_attributes(
          task_name: task_display_name(task, index),
          width: render_result.width,
          height: render_result.height,
          format: render_result.format
        )
        preview.save! if preview.new_record? || preview.changed?
        preview.file.purge if preview.file.attached?
        preview.file.attach(
          io: file,
          filename: "preview-#{render_result.filename}",
          content_type: mime_type(render_result.format)
        )
        cleanup_stale_task_previews!(index, keep: preview)
      end
    end

    def cleanup_stale_task_previews!(index, keep:)
      project.task_previews.where(task_index: index).where.not(id: keep.id).find_each do |preview|
        preview.file.purge if preview.file.attached?
        preview.destroy!
      end
    end

    def current_previews_by_key
      project.task_previews
        .with_attached_file
        .order(created_at: :desc)
        .each_with_object({}) do |preview, previews|
          next unless preview.file.attached?

          previews[preview_key(preview.task_index, preview.task_name, preview.input_signature)] ||= preview
        end
    end

    def with_renderer_batch
      if renderer.respond_to?(:with_reused_browser)
        renderer.with_reused_browser { yield }
      else
        yield
      end
    end

    def renderer
      @renderer ||= Renderer.new(project)
    end

    def preload_dependencies
      ActiveRecord::Associations::Preloader.new(
        records: [ project ],
        associations: [
          { image_assets: { file_attachment: :blob } },
          { font_assets: { file_attachment: :blob } },
          { task_previews: { file_attachment: :blob } }
        ]
      ).call
      GlobalFontAsset.with_attached_file.load
    end

    def preview_key(index, task_name, input_signature)
      [ index.to_i, task_name.to_s, input_signature.to_s ]
    end

    def task_display_name(task, index)
      task["targetName"].presence || "Task #{index + 1}"
    end

    def task_message(index, task_name, message)
      "Task #{index + 1} (#{task_name}): #{message}"
    end

    def mime_type(format)
      case format
      when "png"
        "image/png"
      when "webp"
        "image/webp"
      else
        "image/jpeg"
      end
    end
  end
end
