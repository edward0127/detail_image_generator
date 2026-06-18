require "zip"

module ImageProjects
  class GenerationRunner
    def self.call(project = nil, task_indexes: nil, input_signature: nil, generation_scope: nil, job: nil)
      project ||= job&.image_project
      new(project, task_indexes: task_indexes, input_signature: input_signature, generation_scope: generation_scope, job: job).call
    end

    def initialize(project, task_indexes: nil, input_signature: nil, generation_scope: nil, job: nil)
      @project = project
      raise ArgumentError, "project is required" unless @project

      @job = job
      @renderer = Renderer.new(project)
      @task_indexes = task_indexes.nil? ? task_indexes_from_job : task_indexes
      @generation_scope = generation_scope.presence || @job&.generation_scope.presence || default_generation_scope
      @input_signature = input_signature.presence || @job&.input_signature.presence || default_input_signature
    end

    def call
      preload_dependencies

      generation_job = job || create_generation_job!
      return generation_job if generation_job.downloadable?

      started_clock = monotonic_time
      signature_prefix = input_signature.to_s.first(12)
      Rails.logger.info(
        "ZIP generation job started image_generation_job_id=#{generation_job.id} " \
        "scope=#{generation_scope} signature=#{signature_prefix}"
      )

      generation_job.generated_images.destroy_all if generation_job.generated_images.exists?
      generation_job.update!(
        status: "running",
        started_at: Time.current,
        finished_at: nil,
        warnings_list: [],
        errors_list: [],
        generation_scope: generation_scope,
        input_signature: input_signature,
        task_indexes_json: task_indexes_json
      )
      project.update!(status: "generating", last_error: nil)

      job_warnings = []
      job_errors = []
      tasks = selected_task_pairs
      raise "No tasks were selected for generation." if tasks.blank?

      with_renderer_batch do
        tasks.each do |task, index|
          render_started_clock = monotonic_time
          result = renderer.render_final(task)
          generated = persist_result(generation_job, task, index, result)
          job_warnings << { "targetName" => generated.target_name, "warnings" => result.warnings } if result.warnings.any?
          job_errors << { "targetName" => generated.target_name, "errors" => result.errors } if result.errors.any?
          generation_job.touch
          Rails.logger.info(
            "ZIP generation rendered task image_generation_job_id=#{generation_job.id} " \
            "task_index=#{index} target=#{generated.target_name.inspect} " \
            "duration=#{elapsed_seconds(render_started_clock)}s warnings=#{result.warnings.size} errors=#{result.errors.size}"
          )
        end
      end

      attach_started_clock = monotonic_time
      attach_zip(generation_job)
      Rails.logger.info(
        "ZIP generation attached archive image_generation_job_id=#{generation_job.id} " \
        "duration=#{elapsed_seconds(attach_started_clock)}s generated_images=#{generation_job.generated_images.count}"
      )

      status = job_errors.any? ? "completed_with_errors" : "completed"
      generation_job.update!(
        status: status,
        finished_at: Time.current,
        warnings_list: job_warnings,
        errors_list: job_errors
      )
      project.update!(status: status, last_error: job_errors.presence&.to_json)
      cleanup_old_all_tasks_zip_jobs!(generation_job)
      Rails.logger.info(
        "ZIP generation job completed image_generation_job_id=#{generation_job.id} " \
        "status=#{status} duration=#{elapsed_seconds(started_clock)}s generated_images=#{generation_job.generated_images.count} " \
        "signature=#{signature_prefix}"
      )
      generation_job
    rescue StandardError => error
      failed_job = defined?(generation_job) ? generation_job : job
      failed_job&.update!(
        status: "failed",
        finished_at: Time.current,
        errors_list: Array(failed_job.errors_list) + [ error.message ]
      )
      project.update!(status: "failed", last_error: error.message)
      Rails.logger.error(
        "ZIP generation job failed image_generation_job_id=#{failed_job&.id || "unknown"} " \
        "duration=#{defined?(started_clock) ? elapsed_seconds(started_clock) : "unknown"}s error=#{error.class}: #{error.message}"
      )
      raise
    end

    private

    attr_reader :project, :renderer, :task_indexes, :input_signature, :generation_scope, :job

    def create_generation_job!
      project.image_generation_jobs.create!(
        status: "queued",
        generation_scope: generation_scope,
        input_signature: input_signature,
        task_indexes_json: task_indexes_json
      )
    end

    def default_generation_scope
      task_indexes.nil? ? ImageGenerationJob::ALL_TASKS_ZIP_SCOPE : ImageGenerationJob::SELECTED_TASKS_ZIP_SCOPE
    end

    def default_input_signature
      return unless task_indexes.nil?

      RenderInputSignature.full_zip(project)
    end

    def task_indexes_json
      return if task_indexes.nil?

      JSON.generate(Array(task_indexes).map(&:to_i))
    end

    def task_indexes_from_job
      parsed = JSON.parse(job.task_indexes_json.presence || "null") if job&.task_indexes_json.present?
      parsed if parsed.is_a?(Array)
    rescue JSON::ParserError
      nil
    end

    def selected_task_pairs
      tasks = project.tasks
      indexes = task_indexes.nil? ? (0...tasks.size).to_a : Array(task_indexes).map(&:to_i)

      indexes.filter_map do |index|
        task = tasks[index]
        task.present? ? [ task, index ] : nil
      end
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
          { font_assets: { file_attachment: :blob } }
        ]
      ).call
      GlobalFontAsset.with_attached_file.load
    end

    def persist_result(job, task, index, result)
      target_name = task["targetName"].presence || "Task #{index + 1}"
      generated = job.generated_images.create!(
        target_name: target_name,
        format: result.format,
        width: result.width,
        height: result.height,
        warnings_list: result.warnings,
        errors_list: result.errors
      )

      if result.errors.empty? && result.path.present? && File.exist?(result.path)
        File.open(result.path, "rb") do |file|
          generated.file.attach(
            io: file,
            filename: result.filename,
            content_type: mime_type(result.format)
          )
        end
      end

      generated
    ensure
      ImageProjects::TempfileManager.delete(result.path) if result&.path.present?
    end

    def attach_zip(job)
      ImageProjects::TempfileManager.with_path(prefix: "generated-images-#{job.id}", extension: ".zip", subdir: "zips") do |zip_path|
        Zip::File.open(zip_path, create: true) do |zip|
          used_names = {}
          job.generated_images.includes(file_attachment: :blob).each do |generated|
            next unless generated.file.attached?

            zip_name = unique_name(generated.file.filename.to_s, used_names)
            zip.get_output_stream(zip_name) do |stream|
              generated.file.blob.download { |chunk| stream.write(chunk) }
            end
          end
        end

        File.open(zip_path, "rb") do |file|
          job.zip_file.attach(
            io: file,
            filename: "generated-images-#{job.id}.zip",
            content_type: "application/zip"
          )
        end
      end
    end

    def cleanup_old_all_tasks_zip_jobs!(current_job)
      return unless current_job.generation_scope == ImageGenerationJob::ALL_TASKS_ZIP_SCOPE
      return unless current_job.zip_file.attached?

      project.image_generation_jobs
        .where.not(id: current_job.id)
        .where("generation_scope = ? OR generation_scope IS NULL", ImageGenerationJob::ALL_TASKS_ZIP_SCOPE)
        .where(status: ImageGenerationJob::COMPLETED_CACHE_STATUSES)
        .where("created_at < ?", current_job.created_at)
        .find_each { |job| purge_generation_job!(job) }
    end

    def purge_generation_job!(job)
      job.generated_images.includes(file_attachment: :blob).each do |generated|
        generated.file.purge if generated.file.attached?
      end
      job.zip_file.purge if job.zip_file.attached?
      job.destroy!
    end

    def unique_name(name, used_names)
      base = File.basename(name, File.extname(name))
      extension = File.extname(name)
      candidate = "#{base}#{extension}"
      counter = 2

      while used_names[candidate]
        candidate = "#{base}-#{counter}#{extension}"
        counter += 1
      end

      used_names[candidate] = true
      candidate
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

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_seconds(started_clock)
      (monotonic_time - started_clock).round(3)
    end
  end
end
