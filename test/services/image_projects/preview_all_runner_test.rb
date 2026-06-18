require "test_helper"
require "base64"
require "stringio"

class ImageProjects::PreviewAllRunnerTest < ActiveSupport::TestCase
  PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

  test "generates previews for all previewable tasks" do
    project = text_project([ "P1", "P2", "P3" ])
    renderer = fake_renderer

    result = ImageProjects::PreviewAllRunner.call(project, renderer: renderer)

    assert_equal 3, result.total_count
    assert_equal 3, result.previewable_count
    assert_equal 3, result.regenerated_count
    assert_equal 0, result.reused_count
    assert_equal 0, result.skipped_count
    assert_equal 0, result.failed_count
    assert_equal [ "P1", "P2", "P3" ], renderer.rendered_names
    assert_equal [ 0.5, 0.5, 0.5 ], renderer.scales
    assert_equal 1, renderer.batch_count
    assert_equal [ 0, 1, 2 ], project.task_previews.order(:task_index).pluck(:task_index)
    assert project.task_previews.all? { |preview| preview.file.attached? }
  end

  test "reuses current cached previews and renders only missing previews" do
    project = text_project([ "P1", "P2" ])
    p1_preview = attach_preview(project, task_index: 0, task_name: "P1")
    old_blob = p1_preview.file.blob
    renderer = fake_renderer

    result = ImageProjects::PreviewAllRunner.call(project, renderer: renderer)

    assert_equal 1, result.regenerated_count
    assert_equal 1, result.reused_count
    assert_equal [ "P2" ], renderer.rendered_names
    assert_equal 2, project.task_previews.count
    assert ActiveStorage::Blob.exists?(old_blob.id)
    assert old_blob.service.exist?(old_blob.key)
  end

  test "regenerates outdated previews and cleans only that task stale preview" do
    project = text_project([ "P1", "P2" ])
    stale_preview = attach_preview(project, task_index: 0, task_name: "P1")
    p2_preview = attach_preview(project, task_index: 1, task_name: "P2")
    p2_blob = p2_preview.file.blob

    config = project.config_hash
    config["tasks"][0]["layers"][0]["text"] = "Changed P1 copy"
    project.update_config!(config)
    renderer = fake_renderer

    result = ImageProjects::PreviewAllRunner.call(project.reload, renderer: renderer)

    assert_equal 1, result.regenerated_count
    assert_equal 1, result.reused_count
    assert_equal [ "P1" ], renderer.rendered_names
    refute TaskPreview.exists?(stale_preview.id)
    assert TaskPreview.exists?(p2_preview.id)
    assert ActiveStorage::Blob.exists?(p2_blob.id)
  end

  test "skips invalid tasks while previewing valid text only tasks" do
    project = mixed_project
    renderer = fake_renderer

    result = ImageProjects::PreviewAllRunner.call(project, renderer: renderer)

    assert_equal 3, result.total_count
    assert_equal 1, result.previewable_count
    assert_equal 1, result.regenerated_count
    assert_equal 2, result.skipped_count
    assert_equal 0, result.failed_count
    assert_equal [ "Text Only" ], renderer.rendered_names
    assert_equal [ "Missing Image", "Empty" ], result.skipped_tasks.map { |task| task[:task_name] }
    assert_match "Generated 1 preview, skipped 2 invalid tasks.", result.summary_message
  end

  test "all current previews are reused without rendering" do
    project = text_project([ "P1", "P2" ])
    attach_preview(project, task_index: 0, task_name: "P1")
    attach_preview(project, task_index: 1, task_name: "P2")
    renderer = fake_renderer

    result = ImageProjects::PreviewAllRunner.call(project, renderer: renderer)

    assert_equal 0, result.regenerated_count
    assert_equal 2, result.reused_count
    assert_equal [], renderer.rendered_names
    assert_equal "All previews are already up to date.", result.summary_message
  end

  test "renderer failures are counted without stopping remaining tasks" do
    project = text_project([ "P1", "P2", "P3" ])
    renderer = fake_renderer(fail_names: [ "P2" ])

    result = ImageProjects::PreviewAllRunner.call(project, renderer: renderer)

    assert_equal 2, result.regenerated_count
    assert_equal 1, result.failed_count
    assert_equal [ "P1", "P2", "P3" ], renderer.rendered_names
    assert_equal [ "P2" ], result.failed_tasks.map { |task| task[:task_name] }
  end

  private

  class FakeRenderer
    attr_reader :rendered_names, :scales, :batch_count

    def initialize(test_case, fail_names: [])
      @test_case = test_case
      @fail_names = fail_names
      @rendered_names = []
      @scales = []
      @batch_count = 0
      @in_batch = false
    end

    def with_reused_browser
      @batch_count += 1
      @in_batch = true
      yield
    ensure
      @in_batch = false
    end

    def render_preview(task, scale:)
      raise "Preview All should render inside the renderer batch" unless @in_batch

      task_name = task["targetName"]
      @rendered_names << task_name
      @scales << scale
      return failed_result(task_name) if @fail_names.include?(task_name)

      @test_case.send(:preview_result_for, task_name)
    end

    private

    def failed_result(task_name)
      ImageProjects::Renderer::RenderResult.new(
        path: nil,
        filename: "#{task_name}.png",
        format: "png",
        width: nil,
        height: nil,
        warnings: [],
        errors: [ "failed #{task_name}" ]
      )
    end
  end

  def fake_renderer(fail_names: [])
    FakeRenderer.new(self, fail_names: fail_names)
  end

  def text_project(names)
    project = ImageProject.create!(name: "Bulk Preview")
    project.update_config!(
      "projectName" => "Bulk Preview",
      "tasks" => names.map { |name| text_task(name) }
    )
    project
  end

  def mixed_project
    project = ImageProject.create!(name: "Mixed Bulk Preview")
    project.update_config!(
      "projectName" => "Mixed Bulk Preview",
      "tasks" => [
        text_task("Text Only"),
        image_task("Missing Image", "missing-source"),
        text_task("Empty").merge("layers" => [])
      ]
    )
    project
  end

  def text_task(target_name)
    {
      "targetName" => target_name,
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

  def image_task(target_name, image_name)
    {
      "targetName" => target_name,
      "canvas" => { "width" => 100, "height" => 80, "backgroundColor" => "#FFFFFF", "transparent" => false },
      "output" => { "width" => 100, "height" => 80, "format" => "png" },
      "layers" => [
        {
          "id" => "layer0",
          "name" => "Image",
          "type" => "image",
          "imageName" => image_name,
          "width" => 80,
          "height" => 60,
          "x" => "center",
          "y" => 0,
          "fit" => "contain",
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

  def preview_result_for(task_name)
    tempfile = Tempfile.new([ "preview-#{task_name}", ".png" ])
    tempfile.binmode
    tempfile.write(Base64.decode64(PNG_1X1))
    tempfile.close
    (@preview_tempfiles ||= []) << tempfile

    ImageProjects::Renderer::RenderResult.new(
      path: tempfile.path,
      filename: "#{task_name}.png",
      format: "png",
      width: 1,
      height: 1,
      warnings: [],
      errors: []
    )
  end
end
