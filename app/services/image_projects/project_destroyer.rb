module ImageProjects
  class ProjectDestroyer
    def self.call(project)
      new(project).call
    end

    def initialize(project)
      @project = project
    end

    def call
      purge_project_attachments
      project.destroy!
    end

    private

    attr_reader :project

    def purge_project_attachments
      project.preview_file.purge if project.preview_file.attached?

      project.task_previews.includes(file_attachment: :blob).find_each do |preview|
        preview.file.purge if preview.file.attached?
      end

      project.image_assets.includes(file_attachment: :blob).find_each do |asset|
        asset.file.purge if asset.file.attached?
      end

      project.font_assets.includes(file_attachment: :blob).find_each do |asset|
        asset.file.purge if asset.file.attached?
      end

      project.image_generation_jobs.includes(:zip_file_attachment, generated_images: { file_attachment: :blob }).find_each do |job|
        job.generated_images.each do |generated|
          generated.file.purge if generated.file.attached?
        end
        job.zip_file.purge if job.zip_file.attached?
      end
    end
  end
end
