module ImageProjects
  class GeneratePreviewJob < ApplicationJob
    queue_as :image_generation

    discard_on ActiveJob::DeserializationError

    def perform(preview_generation_job_id)
      preview_job = PreviewGenerationJob.find(preview_generation_job_id)
      PreviewGenerationRunner.call(preview_job.image_project, job: preview_job)
    end
  end
end
