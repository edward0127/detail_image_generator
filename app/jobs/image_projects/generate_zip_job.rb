module ImageProjects
  class GenerateZipJob < ApplicationJob
    queue_as :image_generation

    discard_on ActiveJob::DeserializationError

    def perform(image_generation_job_id)
      generation_job = ImageGenerationJob.find(image_generation_job_id)
      GenerationRunner.call(generation_job.image_project, job: generation_job)
    end
  end
end
