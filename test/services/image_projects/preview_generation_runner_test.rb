require "test_helper"
require "base64"
require "securerandom"
require "stringio"

class ImageProjects::PreviewGenerationRunnerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "selected preview cache hit returns cached without enqueueing" do
    project = text_project([ "P1" ])
    preview = attach_preview(project, task_index: 0, task_name: "P1")

    assert_no_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
      result = ImageProjects::PreviewGenerationRunner.prepare_selected(project, task_index: 0)

      assert_equal :cached, result[:state]
      assert_equal preview.id, result[:preview].id
    end
  end

  test "selected preview cache miss creates queued job and reuses duplicate" do
    project = text_project([ "P1" ])

    assert_enqueued_jobs 1, only: ImageProjects::GeneratePreviewJob do
      result = ImageProjects::PreviewGenerationRunner.prepare_selected(project, task_index: 0)

      assert_equal :queued, result[:state]
      assert result[:enqueued]
    end

    queued_job = project.preview_generation_jobs.last
    assert_equal "queued", queued_job.status
    assert_equal PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE, queued_job.scope
    assert_equal [ 0 ], queued_job.task_indexes

    clear_enqueued_jobs
    assert_no_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
      result = ImageProjects::PreviewGenerationRunner.prepare_selected(project.reload, task_index: 0)

      assert_equal :queued, result[:state]
      assert_equal queued_job.id, result[:job].id
      assert_equal false, result[:enqueued]
    end
  end

  test "stale running selected preview job is failed and a new job is queued" do
    project = text_project([ "P1" ])
    signature = ImageProjects::RenderInputSignature.preview_task(project, 0)
    stale_job = create_preview_job(
      project,
      status: "running",
      scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE,
      task_indexes: [ 0 ],
      input_signature: signature
    )
    stale_job.update_columns(started_at: 2.hours.ago, updated_at: 2.hours.ago)

    assert_enqueued_jobs 1, only: ImageProjects::GeneratePreviewJob do
      result = ImageProjects::PreviewGenerationRunner.prepare_selected(project.reload, task_index: 0)

      assert_equal :queued, result[:state]
      refute_equal stale_job.id, result[:job].id
      assert result[:enqueued]
    end

    assert_equal "failed", stale_job.reload.status
    assert_equal [ PreviewGenerationJob::STALE_RUNNING_MESSAGE ], stale_job.errors_list
    assert_equal "queued", project.preview_generation_jobs.order(:created_at).last.status
  end

  test "non-stale running selected preview job is reused" do
    project = text_project([ "P1" ])
    signature = ImageProjects::RenderInputSignature.preview_task(project, 0)
    running_job = create_preview_job(
      project,
      status: "running",
      scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE,
      task_indexes: [ 0 ],
      input_signature: signature
    )

    assert_no_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
      result = ImageProjects::PreviewGenerationRunner.prepare_selected(project.reload, task_index: 0)

      assert_equal :running, result[:state]
      assert_equal running_job.id, result[:job].id
      assert_equal false, result[:enqueued]
    end

    assert_equal "running", running_job.reload.status
  end

  test "preview all queues only missing previews and records reused count" do
    project = text_project([ "P1", "P2" ])
    attach_preview(project, task_index: 0, task_name: "P1")

    assert_enqueued_jobs 1, only: ImageProjects::GeneratePreviewJob do
      result = ImageProjects::PreviewGenerationRunner.prepare_all(project)

      assert_equal :queued, result[:state]
      assert_equal 1, result[:reused_count]
      assert_equal 2, result[:previewable_count]
    end

    queued_job = project.preview_generation_jobs.last
    assert_equal PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE, queued_job.scope
    assert_equal [ 1 ], queued_job.task_indexes
    assert_equal 1, queued_job.reused_count
  end

  test "stale running preview-all job is failed and a new job is queued" do
    project = text_project([ "P1", "P2" ])
    signature = ImageProjects::PreviewGenerationRunner.preview_all_signature(project)
    stale_job = create_preview_job(
      project,
      status: "running",
      scope: PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE,
      task_indexes: [ 0, 1 ],
      input_signature: signature
    )
    stale_job.update_columns(started_at: 2.hours.ago, updated_at: 2.hours.ago)

    assert_enqueued_jobs 1, only: ImageProjects::GeneratePreviewJob do
      result = ImageProjects::PreviewGenerationRunner.prepare_all(project.reload)

      assert_equal :queued, result[:state]
      refute_equal stale_job.id, result[:job].id
      assert result[:enqueued]
    end

    assert_equal "failed", stale_job.reload.status
    assert_equal [ PreviewGenerationJob::STALE_RUNNING_MESSAGE ], stale_job.errors_list
  end

  test "non-stale running preview-all job is reused" do
    project = text_project([ "P1", "P2" ])
    signature = ImageProjects::PreviewGenerationRunner.preview_all_signature(project)
    running_job = create_preview_job(
      project,
      status: "running",
      scope: PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE,
      task_indexes: [ 0, 1 ],
      input_signature: signature
    )

    assert_no_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
      result = ImageProjects::PreviewGenerationRunner.prepare_all(project.reload)

      assert_equal :running, result[:state]
      assert_equal running_job.id, result[:job].id
      assert_equal false, result[:enqueued]
    end

    assert_equal "running", running_job.reload.status
  end

  test "preview all cache hit returns without enqueueing" do
    project = text_project([ "P1", "P2" ])
    attach_preview(project, task_index: 0, task_name: "P1")
    attach_preview(project, task_index: 1, task_name: "P2")

    assert_no_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
      result = ImageProjects::PreviewGenerationRunner.prepare_all(project)

      assert_equal :cached, result[:state]
      assert_equal "All previews are already up to date.", result[:message]
      assert_equal 2, result[:reused_count]
    end
  end

  test "background all preview job renders with one reused browser batch" do
    project = text_project([ "P1", "P2", "P3" ])
    result = ImageProjects::PreviewGenerationRunner.prepare_all(project)
    preview_job = result[:job]
    renderer = fake_renderer

    ImageProjects::PreviewGenerationRunner.call(project.reload, job: preview_job, renderer: renderer)

    assert_equal "completed", preview_job.reload.status
    assert_equal 3, preview_job.generated_count
    assert_equal 0, preview_job.failed_count
    assert_equal [ "P1", "P2", "P3" ], renderer.rendered_names
    assert_equal 1, renderer.batch_count
    assert_equal [ 0, 1, 2 ], project.task_previews.order(:task_index).pluck(:task_index)
  end

  private

  class FakeRenderer
    attr_reader :rendered_names, :batch_count

    def initialize(test_case)
      @test_case = test_case
      @rendered_names = []
      @batch_count = 0
    end

    def with_reused_browser
      @batch_count += 1
      yield
    end

    def render_preview(task, scale:)
      raise "Expected preview scale 0.5" unless scale == 0.5

      @rendered_names << task["targetName"]
      @test_case.send(:preview_result_for, task["targetName"])
    end
  end

  def fake_renderer
    FakeRenderer.new(self)
  end

  def text_project(names)
    project = ImageProject.create!(name: "Preview Jobs")
    project.update_config!(
      "projectName" => "Preview Jobs",
      "tasks" => names.map { |name| text_task(name) }
    )
    project
  end

  def text_task(target_name)
    {
      "targetName" => target_name,
      "layoutMode" => "strict",
      "canvas" => { "width" => 100, "height" => 80, "backgroundColor" => "#FFFFFF", "transparent" => false },
      "output" => { "width" => 100, "height" => 80, "format" => "png" },
      "layers" => [
        {
          "id" => "layer0",
          "name" => "Text",
          "type" => "text",
          "text" => "#{target_name} copy",
          "font" => "",
          "fontSize" => 24,
          "color" => "#111111",
          "letterSpacingRatio" => 0,
          "lineHeightRatio" => 1.2,
          "maxWidth" => 80,
          "autoWrap" => true,
          "bold" => false,
          "italic" => false,
          "x" => "center",
          "y" => 20,
          "align" => "center",
          "opacity" => 1
        }
      ]
    }
  end

  def attach_preview(project, task_index:, task_name:)
    preview = project.task_previews.create!(
      task_index: task_index,
      task_name: task_name,
      input_signature: ImageProjects::RenderInputSignature.preview_task(project, task_index),
      width: 1,
      height: 1,
      format: "png"
    )
    preview.file.attach(
      io: StringIO.new(Base64.decode64(PNG_1X1)),
      filename: "preview-#{task_name}.png",
      content_type: "image/png"
    )
    preview
  end

  def create_preview_job(project, status:, scope:, task_indexes:, input_signature:)
    project.preview_generation_jobs.create!(
      status: status,
      scope: scope,
      task_indexes_json: JSON.generate(task_indexes),
      task_signatures_json: JSON.generate(task_indexes.to_h { |index| [ index.to_s, ImageProjects::RenderInputSignature.preview_task(project, index) ] }),
      input_signature: input_signature,
      total_count: project.tasks.size,
      previewable_count: task_indexes.size,
      generated_count: 0,
      reused_count: 0,
      skipped_count: 0,
      failed_count: 0
    )
  end

  def preview_result_for(task_name)
    path = Rails.root.join("tmp", "preview-#{task_name}-#{SecureRandom.hex(8)}.png").to_s
    File.binwrite(path, Base64.decode64(PNG_1X1))

    ImageProjects::Renderer::RenderResult.new(
      path: path,
      filename: "#{task_name}.png",
      format: "png",
      width: 1,
      height: 1,
      warnings: [],
      errors: []
    )
  end
end
