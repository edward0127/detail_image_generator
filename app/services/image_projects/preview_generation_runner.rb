require "digest"

module ImageProjects
  class PreviewGenerationRunner
    PREVIEW_SCALE = 0.5

    class << self
      def prepare_selected(project, task_index:)
        new(project).prepare_selected(task_index)
      end

      def prepare_all(project)
        new(project).prepare_all
      end

      def call(project = nil, job:, renderer: nil)
        project ||= job&.image_project
        new(project, job: job, renderer: renderer).call
      end

      def preview_all_signature(project)
        entries = previewable_signature_entries(project)
        digest_for(
          "version" => RenderInputSignature::VERSION,
          "mode" => "preview_all",
          "tasks" => entries.map { |entry| entry.slice(:index, :input_signature) }
        )
      end

      def previewable_signature_entries(project)
        signature_builder = RenderInputSignature.new(project)
        readiness_checker = TaskPreviewReadiness.new(project)

        project.tasks.each_with_index.filter_map do |task, index|
          readiness = readiness_checker.call(task)
          next unless readiness[:ready]

          {
            task: task,
            index: index,
            task_name: task_display_name(task, index),
            input_signature: signature_builder.preview_task(index)
          }
        end
      end

      private

      def task_display_name(task, index)
        task["targetName"].presence || "Task #{index + 1}"
      end

      def digest_for(payload)
        Digest::SHA256.hexdigest(RenderInputSignature.canonical_json(payload))
      end
    end

    def initialize(project, job: nil, renderer: nil)
      @project = project
      raise ArgumentError, "project is required" unless @project

      @job = job
      @renderer = renderer
    end

    def prepare_selected(task_index)
      task = project.tasks[task_index]
      raise "No task exists at index #{task_index}." if task.blank?

      readiness = TaskPreviewReadiness.call(project, task)
      raise readiness[:alert] unless readiness[:ready]

      task_name = task_display_name(task, task_index)
      input_signature = RenderInputSignature.preview_task(project, task_index)
      cached_preview = current_preview_for(task_index, task_name, input_signature)
      if cached_preview
        return {
          state: :cached,
          preview: cached_preview,
          task_index: task_index,
          input_signature: input_signature,
          message: "Preview is already up to date."
        }
      end

      result = nil
      project.with_lock do
        active_job = active_selected_job_for(task_index, input_signature)
        active_job ||= active_all_job_covering(task_index)
        if active_job
          result = {
            state: active_job.status.to_sym,
            job: active_job,
            task_index: task_index,
            input_signature: input_signature,
            enqueued: false,
            message: selected_job_message(active_job)
          }
        else
          preview_job = project.preview_generation_jobs.create!(
            status: "queued",
            scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE,
            task_indexes_json: JSON.generate([ task_index.to_i ]),
            task_signatures_json: JSON.generate(task_index.to_s => input_signature),
            input_signature: input_signature,
            total_count: 1,
            previewable_count: 1,
            generated_count: 0,
            reused_count: 0,
            skipped_count: 0,
            failed_count: 0
          )
          result = {
            state: :queued,
            job: preview_job,
            task_index: task_index,
            input_signature: input_signature,
            enqueued: true,
            message: "Preview generation started. You can keep editing while it runs."
          }
        end
      end

      enqueue_preview_generation!(result[:job]) if result[:enqueued]
      result
    end

    def prepare_all
      readiness_checker = TaskPreviewReadiness.new(project)
      signature_builder = RenderInputSignature.new(project)
      previews_by_key = current_previews_by_key
      skipped_tasks = []
      all_previewable_entries = []
      missing_entries = []
      reused_count = 0

      project.tasks.each_with_index do |task, index|
        task_name = task_display_name(task, index)
        readiness = readiness_checker.call(task)
        unless readiness[:ready]
          skipped_tasks << {
            index: index,
            task_name: task_name,
            message: readiness[:message],
            alert: readiness[:alert]
          }
          next
        end

        input_signature = signature_builder.preview_task(index)
        entry = {
          task: task,
          index: index,
          task_name: task_name,
          input_signature: input_signature
        }
        all_previewable_entries << entry

        if previews_by_key[preview_key(index, task_name, input_signature)]
          reused_count += 1
        else
          missing_entries << entry
        end
      end

      if all_previewable_entries.empty?
        return {
          state: :no_previewable,
          total_count: project.tasks.size,
          previewable_count: 0,
          generated_count: 0,
          reused_count: 0,
          skipped_count: skipped_tasks.size,
          failed_count: 0,
          skipped_tasks: skipped_tasks,
          message: no_previewable_message(skipped_tasks)
        }
      end

      input_signature = self.class.send(
        :digest_for,
        "version" => RenderInputSignature::VERSION,
        "mode" => "preview_all",
        "tasks" => all_previewable_entries.map { |entry| entry.slice(:index, :input_signature) }
      )

      if missing_entries.empty?
        return {
          state: :cached,
          input_signature: input_signature,
          total_count: project.tasks.size,
          previewable_count: all_previewable_entries.size,
          generated_count: 0,
          reused_count: reused_count,
          skipped_count: skipped_tasks.size,
          failed_count: 0,
          skipped_tasks: skipped_tasks,
          message: "All previews are already up to date."
        }
      end

      result = nil
      project.with_lock do
        active_job = active_all_job_for(input_signature)
        if active_job
          result = {
            state: active_job.status.to_sym,
            job: active_job,
            input_signature: input_signature,
            enqueued: false,
            message: all_job_message(active_job)
          }
        else
          preview_job = project.preview_generation_jobs.create!(
            status: "queued",
            scope: PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE,
            task_indexes_json: JSON.generate(missing_entries.map { |entry| entry[:index] }),
            task_signatures_json: JSON.generate(missing_entries.to_h { |entry| [ entry[:index].to_s, entry[:input_signature] ] }),
            input_signature: input_signature,
            total_count: project.tasks.size,
            previewable_count: all_previewable_entries.size,
            generated_count: 0,
            reused_count: reused_count,
            skipped_count: skipped_tasks.size,
            failed_count: 0,
            warnings_list: skipped_tasks.map { |task| task[:message] }.compact_blank
          )
          result = {
            state: :queued,
            job: preview_job,
            input_signature: input_signature,
            enqueued: true,
            message: "Preview generation started for #{missing_entries.size} #{'task'.pluralize(missing_entries.size)}."
          }
        end
      end

      enqueue_preview_generation!(result[:job]) if result[:enqueued]
      result.merge(
        total_count: project.tasks.size,
        previewable_count: all_previewable_entries.size,
        reused_count: result[:job]&.reused_count || reused_count,
        skipped_count: result[:job]&.skipped_count || skipped_tasks.size,
        failed_count: result[:job]&.failed_count || 0
      )
    end

    def call
      preload_dependencies
      start_job!
      initialize_progress_from_job

      case job.scope
      when PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE
        render_selected_job
      when PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE
        render_all_job
      else
        raise "Unknown preview generation scope: #{job.scope}"
      end

      finish_job!
      job
    rescue StandardError => error
      mark_failed!(error)
      raise
    end

    private

    attr_reader :project, :job

    def renderer
      @renderer ||= Renderer.new(project)
    end

    def enqueue_preview_generation!(preview_job)
      queued = ImageProjects::GeneratePreviewJob.perform_later(preview_job.id)
      raise "Preview generation could not be queued." unless queued

      Rails.logger.info(
        "Preview generation job queued image_project_id=#{project.id} preview_generation_job_id=#{preview_job.id} " \
        "active_job_id=#{queued.job_id} queue=#{queued.queue_name} scope=#{preview_job.scope} " \
        "signature=#{preview_job.input_signature.to_s.first(12)}"
      )
    rescue StandardError => error
      preview_job.update!(
        status: "failed",
        finished_at: Time.current,
        errors_list: [ "Queue enqueue failed: #{error.message}" ]
      )
      Rails.logger.error(
        "Preview generation enqueue failed image_project_id=#{project.id} preview_generation_job_id=#{preview_job.id} " \
        "signature=#{preview_job.input_signature.to_s.first(12)} error=#{error.class}: #{error.message}"
      )
      raise
    end

    def render_selected_job
      task_index = job.task_indexes.first
      expected_signature = job.input_signature
      render_preview_for_index(task_index, expected_signature)
    end

    def render_all_job
      with_renderer_batch do
        job.task_indexes.each do |task_index|
          render_preview_for_index(task_index, job.task_signatures[task_index.to_s])
        end
      end
    end

    def render_preview_for_index(task_index, expected_signature)
      task = project.tasks[task_index]
      task_name = task_display_name(task || {}, task_index)

      if task.blank?
        add_skip!("Task #{task_index + 1} no longer exists.")
        persist_progress!
        return
      end

      readiness = TaskPreviewReadiness.call(project, task)
      unless readiness[:ready]
        add_skip!(readiness[:message] || "Task #{task_index + 1} is no longer previewable.")
        persist_progress!
        return
      end

      current_signature = RenderInputSignature.preview_task(project, task_index)
      if expected_signature.present? && current_signature != expected_signature
        add_skip!("Task #{task_index + 1} (#{task_name}) changed before preview generation ran.")
        persist_progress!
        return
      end

      if current_preview_for(task_index, task_name, current_signature)
        @reused_count += 1
        persist_progress!
        return
      end

      render_result = renderer.render_preview(task, scale: PREVIEW_SCALE)
      collect_render_messages(render_result, task_index, task_name)

      unless render_result.path.present? && File.exist?(render_result.path)
        @failed_count += 1
        errors = render_result.errors.presence || [ "Renderer did not produce a preview file." ]
        errors.each { |message| @errors << task_message(task_index, task_name, message) }
        persist_progress!
        return
      end

      attach_preview_result!(render_result, task, task_index, current_signature)
      @generated_count += 1
      persist_progress!
    rescue StandardError => error
      @failed_count += 1
      @errors << task_message(task_index, task_name, error.message)
      persist_progress!
    ensure
      ImageProjects::TempfileManager.delete(render_result.path) if render_result&.path.present? && File.exist?(render_result.path)
    end

    def start_job!
      job.update!(
        status: "running",
        started_at: Time.current,
        finished_at: nil,
        generated_count: 0,
        failed_count: 0,
        warnings_list: [],
        errors_list: []
      )
    end

    def initialize_progress_from_job
      @generated_count = job.generated_count.to_i
      @reused_count = job.reused_count.to_i
      @skipped_count = job.skipped_count.to_i
      @failed_count = job.failed_count.to_i
      @warnings = job.warnings_list
      @errors = job.errors_list
    end

    def finish_job!
      status = @failed_count.positive? ? "completed_with_errors" : "completed"
      job.update!(
        status: status,
        finished_at: Time.current,
        generated_count: @generated_count,
        reused_count: @reused_count,
        skipped_count: @skipped_count,
        failed_count: @failed_count,
        warnings_list: @warnings,
        errors_list: @errors
      )
    end

    def persist_progress!
      job.update!(
        generated_count: @generated_count,
        reused_count: @reused_count,
        skipped_count: @skipped_count,
        failed_count: @failed_count,
        warnings_list: @warnings,
        errors_list: @errors
      )
    end

    def mark_failed!(error)
      return unless job

      job.update!(
        status: "failed",
        finished_at: Time.current,
        generated_count: @generated_count.to_i,
        reused_count: @reused_count.to_i,
        skipped_count: @skipped_count.to_i,
        failed_count: @failed_count.to_i,
        warnings_list: Array(@warnings),
        errors_list: Array(@errors) + [ error.message ]
      )
    end

    def add_skip!(message)
      @skipped_count += 1
      @warnings << message
    end

    def collect_render_messages(render_result, index, task_name)
      Array(render_result.warnings).each do |warning|
        @warnings << task_message(index, task_name, warning)
      end

      Array(render_result.errors).each do |error|
        @errors << task_message(index, task_name, error)
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
        cleanup_stale_task_previews!(index, keep: preview, input_signature: input_signature)
      end
    end

    def cleanup_stale_task_previews!(index, keep:, input_signature:)
      return unless RenderInputSignature.preview_task(project.reload, index) == input_signature

      project.task_previews.where(task_index: index).where.not(id: keep.id).find_each do |preview|
        preview.file.purge if preview.file.attached?
        preview.destroy!
      end
    rescue StandardError => error
      Rails.logger.warn("Preview cleanup skipped image_project_id=#{project.id} task_index=#{index}: #{error.message}")
    end

    def active_selected_job_for(task_index, input_signature)
      project.preview_generation_jobs
        .for_signature(scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE, input_signature: input_signature)
        .active
        .order(created_at: :desc)
        .each do |preview_job|
          next unless preview_job.task_indexes == [ task_index.to_i ]
          next if refresh_stale_running_job!(preview_job)

          return preview_job
        end

      nil
    end

    def active_all_job_for(input_signature)
      project.preview_generation_jobs
        .for_signature(scope: PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE, input_signature: input_signature)
        .active
        .order(created_at: :desc)
        .each do |preview_job|
          next if refresh_stale_running_job!(preview_job)

          return preview_job
        end

      nil
    end

    def active_all_job_covering(task_index)
      input_signature = self.class.preview_all_signature(project)
      active_all_job_for(input_signature)&.then do |preview_job|
        preview_job.task_indexes.include?(task_index.to_i) ? preview_job : nil
      end
    rescue StandardError
      nil
    end

    def refresh_stale_running_job!(preview_job)
      return false unless preview_job&.stale_running?

      preview_job.update!(
        status: "failed",
        finished_at: Time.current,
        errors_list: Array(preview_job.errors_list) + [ PreviewGenerationJob::STALE_RUNNING_MESSAGE ]
      )
      Rails.logger.warn(
        "Stale preview generation job marked failed image_project_id=#{project.id} " \
        "preview_generation_job_id=#{preview_job.id} scope=#{preview_job.scope} " \
        "signature=#{preview_job.input_signature.to_s.first(12)}"
      )
      true
    end

    def current_preview_for(index, task_name, input_signature)
      project.task_previews
        .with_attached_file
        .where(task_index: index, task_name: task_name, input_signature: input_signature)
        .order(created_at: :desc)
        .detect { |preview| preview.file.attached? }
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

    def preview_key(index, task_name, input_signature)
      [ index.to_i, task_name.to_s, input_signature.to_s ]
    end

    def selected_job_message(preview_job)
      "Preview generation is #{preview_job.status}. You can keep editing while it runs."
    end

    def all_job_message(preview_job)
      "Preview generation for all images is #{preview_job.status}. You can leave this page and come back later."
    end

    def no_previewable_message(skipped_tasks)
      detail = skipped_tasks.find { |task| task[:alert].present? }&.fetch(:alert)
      return "No previewable tasks found. #{detail}" if detail.present?

      "No previewable tasks found. Import Excel or add at least one previewable task."
    end

    def with_renderer_batch(&block)
      if renderer.respond_to?(:with_reused_browser)
        renderer.with_reused_browser(&block)
      else
        yield
      end
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
