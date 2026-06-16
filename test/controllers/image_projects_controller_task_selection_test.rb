require "test_helper"
require "base64"
require "stringio"

class ImageProjectsControllerTaskSelectionTest < ActionDispatch::IntegrationTest
  PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
  FakeJob = Struct.new(:status, :generated_images, :zip_file)
  FakeZipBlob = Struct.new(:bytes) do
    def download
      yield bytes
    end
  end
  FakeZipFile = Struct.new(:filename, :blob) do
    def attached?
      true
    end
  end

  test "task list renders selectable P1 and P2 cards" do
    project = create_project_with_tasks

    get image_project_path(project)

    assert_response :success
    assert_select ".task-title", text: "P1"
    assert_select ".task-title", text: "P2"
    assert_select "a.task-select-card[href='#{image_project_path(project, task_index: 0)}']" do
      assert_select ".selection-badge", text: "Selected"
    end
    assert_select "a.task-select-card[href='#{image_project_path(project, task_index: 1)}']" do
      assert_select ".selection-badge", text: "Select"
    end
    assert_includes response.body, "Select a task below to preview that image."
  end

  test "task index one selects P2 across actions preview settings and warnings" do
    project = create_project_with_tasks

    get image_project_path(project, task_index: 1)

    assert_response :success
    assert_select "a.task-select-card[aria-current='page'][href='#{image_project_path(project, task_index: 1)}']" do
      assert_select ".task-title", text: "P2"
      assert_select ".selection-badge", text: "Selected"
    end
    assert_includes response.body, "Selected Image: <strong>P2</strong>"
    assert_includes response.body, "Preview Selected Image"
    assert_includes response.body, "Download ZIP (All Images)"
    refute_includes response.body, "Generate P2"
    assert_includes response.body, "Preview for P2"
    assert_includes response.body, "Warnings / Errors for P2"
    assert_select "input[name='task[targetName]'][value='P2']"
    assert_select "input[name='task[canvas][width]'][value='220']"
    assert_select "select[name='task[output][format]'] option[selected='selected'][value='jpg']"
  end

  test "preview panel does not show P1 preview as P2 preview" do
    project = create_project_with_tasks
    attach_preview(project, task_index: 0, task_name: "P1")

    get image_project_path(project, task_index: 1)

    assert_response :success
    assert_select "img.preview-image", count: 0
    assert_includes response.body, "No preview generated for P2 yet."
    assert_includes response.body, "Click Preview Selected Image to generate one."
    assert_includes response.body, "Last preview belongs to P1."

    get image_project_path(project, task_index: 0)

    assert_response :success
    assert_select "img.preview-image", count: 1
    assert_includes response.body, "Preview for P1"
  end

  test "preview action stores selected task context" do
    project = create_project_with_tasks
    old_blob = attach_preview(project, task_index: 0, task_name: "P1")
    tempfile = Tempfile.new([ "preview-p2", ".png" ])
    tempfile.binmode
    tempfile.write(Base64.decode64(PNG_1X1))
    tempfile.close
    result = ImageProjects::Renderer::RenderResult.new(
      path: tempfile.path,
      filename: "P2.png",
      format: "png",
      width: 1,
      height: 1,
      warnings: [],
      errors: []
    )
    renderer = Object.new
    test_case = self
    renderer.define_singleton_method(:render_preview) do |task, scale:|
      test_case.assert_equal "P2", task["targetName"]
      test_case.assert_equal 0.5, scale
      result
    end

    original_renderer_new = ImageProjects::Renderer.method(:new)
    ImageProjects::Renderer.define_singleton_method(:new) { |*_args, **_kwargs| renderer }
    post preview_image_project_path(project, task_index: 1)

    assert_redirected_to image_project_path(project, task_index: 1)
    assert project.reload.preview_file.attached?
    refute_equal old_blob.id, project.preview_file.blob.id
    refute ActiveStorage::Blob.exists?(old_blob.id)
    refute old_blob.service.exist?(old_blob.key)
    assert_equal 1, project.preview_task_index
    assert_equal "P2", project.preview_task_name
  ensure
    if defined?(original_renderer_new) && original_renderer_new
      ImageProjects::Renderer.define_singleton_method(:new) do |*args, **kwargs, &block|
        original_renderer_new.call(*args, **kwargs, &block)
      end
    end
    File.delete(tempfile.path) if defined?(tempfile) && File.exist?(tempfile.path)
  end

  test "update preview action saves selected task settings before rendering" do
    project = create_project_with_tasks
    preview_text = "**DESIGN** HIGHLIGHTS"
    rendered_task = nil
    rendered_scale = nil
    renderer_project_config = nil
    result = ImageProjects::Renderer::RenderResult.new(
      path: nil,
      filename: "P2.png",
      format: "png",
      width: 1,
      height: 1,
      warnings: [],
      errors: []
    )
    renderer = Object.new
    renderer.define_singleton_method(:render_preview) do |task, scale:|
      rendered_task = task.deep_dup
      rendered_scale = scale
      result
    end
    renderer_factory = lambda do |project_arg|
      renderer_project_config = project_arg.config_hash
      renderer
    end

    with_singleton_method_stub(ImageProjects::Renderer, :new, renderer_factory) do
      patch image_project_path(project), params: editor_update_params(
        index: 1,
        target_name: "P2",
        layer: text_layer_update_params("P2", "text" => preview_text, "fontSize" => "77"),
        after_save_action: "preview_current"
      )
    end

    assert_redirected_to image_project_path(project, task_index: 1)
    assert_equal preview_text, renderer_project_config.dig("tasks", 1, "layers", 0, "text")
    assert_equal preview_text, rendered_task.dig("layers", 0, "text")
    assert_equal 77, rendered_task.dig("layers", 0, "fontSize")
    assert_equal 0.5, rendered_scale
    assert_equal preview_text, project.reload.config_hash.dig("tasks", 1, "layers", 0, "text")
  end

  test "update generate current saves selected task settings before generation" do
    project = create_project_with_tasks
    test_case = self
    generated_task_indexes = nil
    runner = lambda do |project_arg, task_indexes: nil|
      generated_task_indexes = task_indexes
      test_case.assert_equal "P2 current generation text", project_arg.config_hash.dig("tasks", 1, "layers", 0, "text")
      FakeJob.new("completed", [ Object.new ])
    end

    with_singleton_method_stub(ImageProjects::GenerationRunner, :call, runner) do
      patch image_project_path(project), params: editor_update_params(
        index: 1,
        target_name: "P2",
        layer: text_layer_update_params("P2", "text" => "P2 current generation text"),
        after_save_action: "generate_current"
      )
    end

    assert_equal [ 1 ], generated_task_indexes
    assert_redirected_to image_project_path(project, task_index: 1)
    assert_equal "P2 current generation text", project.reload.config_hash.dig("tasks", 1, "layers", 0, "text")
  end

  test "update generate all saves selected task settings before generation" do
    project = create_project_with_tasks
    test_case = self
    generated_task_indexes = :not_called
    runner = lambda do |project_arg, task_indexes: nil|
      generated_task_indexes = task_indexes
      test_case.assert_equal "P2 all generation text", project_arg.config_hash.dig("tasks", 1, "layers", 0, "text")
      FakeJob.new("completed", [ Object.new, Object.new ])
    end

    with_singleton_method_stub(ImageProjects::GenerationRunner, :call, runner) do
      patch image_project_path(project), params: editor_update_params(
        index: 1,
        target_name: "P2",
        layer: text_layer_update_params("P2", "text" => "P2 all generation text"),
        after_save_action: "generate_all"
      )
    end

    assert_nil generated_task_indexes
    assert_redirected_to image_project_path(project, task_index: 1)
    assert_equal "P2 all generation text", project.reload.config_hash.dig("tasks", 1, "layers", 0, "text")
  end

  test "update download zip saves selected task settings before generating all tasks" do
    project = create_project_with_tasks
    zip_text = "**DESIGN** HIGHLIGHTS"
    test_case = self
    zip_file = fake_zip_file("generated.zip", "zip-bytes")
    generated_task_indexes = :not_called
    runner = lambda do |project_arg, task_indexes: nil|
      generated_task_indexes = task_indexes
      test_case.assert_equal zip_text, project_arg.config_hash.dig("tasks", 1, "layers", 0, "text")
      FakeJob.new("completed", [ Object.new, Object.new ], zip_file)
    end

    with_singleton_method_stub(ImageProjects::GenerationRunner, :call, runner) do
      patch image_project_path(project), params: editor_update_params(
        index: 1,
        target_name: "P2",
        layer: text_layer_update_params("P2", "text" => zip_text),
        after_save_action: "download_zip"
      )
    end

    assert_nil generated_task_indexes
    assert_response :success
    assert_equal "application/zip", response.media_type
    assert_equal "zip-bytes", response.body
    assert_match "attachment", response.headers["Content-Disposition"]
    assert_equal zip_text, project.reload.config_hash.dig("tasks", 1, "layers", 0, "text")
  end

  test "invalid task index falls back to a valid task" do
    project = create_project_with_tasks

    get image_project_path(project, task_index: 99)

    assert_response :success
    assert_select "a.task-select-card[aria-current='page'][href='#{image_project_path(project, task_index: 1)}']" do
      assert_select ".task-title", text: "P2"
    end
    assert_includes response.body, "Selected Image: <strong>P2</strong>"

    get image_project_path(project, task_index: -2)

    assert_response :success
    assert_select "a.task-select-card[aria-current='page'][href='#{image_project_path(project, task_index: 0)}']" do
      assert_select ".task-title", text: "P1"
    end
    assert_includes response.body, "Selected Image: <strong>P1</strong>"
  end

  test "task action buttons render with task-specific indexes" do
    project = create_project_with_tasks

    get image_project_path(project, task_index: 1)

    assert_response :success
    assert_select ".task-actions form[action='#{move_task_image_project_path(project, task_index: 1, direction: "up")}']"
    assert_select ".task-actions form[action='#{move_task_image_project_path(project, task_index: 1, direction: "down")}']"
    assert_select ".task-actions form[action='#{duplicate_task_image_project_path(project, task_index: 1)}']"
    assert_select ".task-actions form[action='#{delete_task_image_project_path(project, task_index: 1)}']"
  end

  test "up down duplicate and delete actions preserve usable selection" do
    project = create_project_with_tasks([ "P1", "P2", "P3" ])

    post move_task_image_project_path(project, task_index: 1, direction: "up")
    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal [ "P2", "P1", "P3" ], project.reload.tasks.map { |task| task["targetName"] }

    post move_task_image_project_path(project, task_index: 0, direction: "down")
    assert_redirected_to image_project_path(project, task_index: 1)
    assert_equal [ "P1", "P2", "P3" ], project.reload.tasks.map { |task| task["targetName"] }

    post duplicate_task_image_project_path(project, task_index: 1)
    assert_redirected_to image_project_path(project, task_index: 2)
    assert_equal [ "P1", "P2", "P2 Copy", "P3" ], project.reload.tasks.map { |task| task["targetName"] }

    post delete_task_image_project_path(project, task_index: 2)
    assert_redirected_to image_project_path(project, task_index: 2)
    assert_equal [ "P1", "P2", "P3" ], project.reload.tasks.map { |task| task["targetName"] }
  end

  private

  def create_project_with_tasks(names = [ "P1", "P2" ])
    project = ImageProject.create!(name: "Task Selection")
    project.update_config!(
      "projectName" => "Task Selection",
      "canvasDefaults" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false, "outputFormat" => "png" },
      "tasks" => names.map.with_index { |name, index| task_config(name, index) }
    )
    project
  end

  def task_config(target_name, index)
    {
      "targetName" => target_name,
      "canvas" => { "width" => 110 * (index + 1), "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
      "output" => { "width" => 1650, "height" => 2480, "format" => index.zero? ? "png" : "jpg" },
      "warnings" => index.zero? ? [] : [ "#{target_name} warning" ],
      "layers" => [
        {
          "id" => "layer0",
          "name" => "#{target_name} Text",
          "type" => "text",
          "text" => "#{target_name} detail copy",
          "font" => "",
          "fontSize" => 60,
          "color" => "#1F1F1F",
          "letterSpacingRatio" => 0,
          "lineHeightRatio" => 1.2,
          "maxWidth" => 1200,
          "autoWrap" => true,
          "bold" => false,
          "italic" => false,
          "x" => "center",
          "y" => 200,
          "align" => "center",
          "opacity" => 1
        }
      ]
    }
  end

  def attach_preview(project, task_index:, task_name:)
    project.preview_file.attach(
      io: StringIO.new(Base64.decode64(PNG_1X1)),
      filename: "preview-#{task_name}.png",
      content_type: "image/png"
    )
    blob = project.preview_file.blob
    project.update!(preview_task_index: task_index, preview_task_name: task_name)
    blob
  end

  def fake_zip_file(filename, bytes)
    FakeZipFile.new(filename, FakeZipBlob.new(bytes))
  end

  def editor_update_params(index:, target_name:, layer:, after_save_action:)
    {
      task_index: index,
      after_save_action: after_save_action,
      image_project: { name: "Task Selection" },
      task: {
        targetName: target_name,
        layoutMode: "strict",
        canvas: { width: (110 * (index + 1)).to_s, height: "2480", backgroundColor: "#FAFAF0", transparent: "0" },
        output: { width: "1650", height: "2480", format: index.zero? ? "png" : "jpg" }
      },
      layers: {
        "0" => layer
      }
    }
  end

  def text_layer_update_params(target_name, overrides = {})
    {
      "id" => "layer0",
      "name" => "#{target_name} Text",
      "type" => "text",
      "text" => "#{target_name} detail copy",
      "font" => "",
      "fontSize" => "60",
      "color" => "#1F1F1F",
      "letterSpacingRatio" => "0",
      "lineHeightRatio" => "1.2",
      "maxWidth" => "1200",
      "autoWrap" => "1",
      "bold" => "0",
      "italic" => "0",
      "x" => "center",
      "y" => "200",
      "align" => "center",
      "opacity" => "1",
      "letterSpacingMode" => "",
      "targetTextWidthRatio" => "0.78",
      "notes" => ""
    }.merge(overrides)
  end

  def with_singleton_method_stub(object, method_name, replacement)
    original_method = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name) do |*args, **kwargs, &block|
      original_method.call(*args, **kwargs, &block)
    end
  end
end
