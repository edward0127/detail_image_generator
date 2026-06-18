module ImageProjects
  class ProjectDataResetter
    def self.call(project)
      new(project).call
    end

    def initialize(project)
      @project = project
    end

    def call
      project.with_lock do
        purge_legacy_preview
        purge_image_assets
        purge_task_previews
        purge_preview_generation_jobs
        purge_image_generation_jobs
        reset_project_config
      end

      project
    end

    private

    attr_reader :project

    def purge_legacy_preview
      project.preview_file.purge if project.preview_file.attached?
    end

    def purge_image_assets
      project.image_assets.includes(file_attachment: :blob).find_each do |asset|
        asset.file.purge if asset.file.attached?
        asset.destroy!
      end
    end

    def purge_task_previews
      project.task_previews.includes(file_attachment: :blob).find_each do |preview|
        preview.file.purge if preview.file.attached?
        preview.destroy!
      end
    end

    def purge_preview_generation_jobs
      project.preview_generation_jobs.find_each(&:destroy!)
    end

    def purge_image_generation_jobs
      project.image_generation_jobs.includes(:zip_file_attachment, generated_images: { file_attachment: :blob }).find_each do |job|
        job.generated_images.each do |generated|
          generated.file.purge if generated.file.attached?
          generated.destroy!
        end
        job.zip_file.purge if job.zip_file.attached?
        job.destroy!
      end
    end

    def reset_project_config
      project.update!(
        config_json: JSON.pretty_generate(DefaultConfig.build(name: project.name)),
        status: "draft",
        last_error: nil
      )
    end
  end
end
