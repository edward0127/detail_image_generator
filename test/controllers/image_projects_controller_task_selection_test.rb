require "test_helper"
require "base64"
require "stringio"

class ImageProjectsControllerTaskSelectionTest < ActionDispatch::IntegrationTest
  PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

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
    assert_includes response.body, "Select a task below to preview or generate that image."
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
    assert_includes response.body, "Preview P2"
    assert_includes response.body, "Generate P2"
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
    assert_includes response.body, "Click Preview P2 to generate one."
    assert_includes response.body, "Last preview belongs to P1."

    get image_project_path(project, task_index: 0)

    assert_response :success
    assert_select "img.preview-image", count: 1
    assert_includes response.body, "Preview for P1"
  end

  test "preview action stores selected task context" do
    project = create_project_with_tasks
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

  test "invalid task index falls back to a valid task" do
    project = create_project_with_tasks

    get image_project_path(project, task_index: 99)

    assert_response :success
    assert_select "a.task-select-card[aria-current='page'][href='#{image_project_path(project, task_index: 1)}']" do
      assert_select ".task-title", text: "P2"
    end
    assert_includes response.body, "Preview P2"

    get image_project_path(project, task_index: -2)

    assert_response :success
    assert_select "a.task-select-card[aria-current='page'][href='#{image_project_path(project, task_index: 0)}']" do
      assert_select ".task-title", text: "P1"
    end
    assert_includes response.body, "Preview P1"
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
    project.update!(preview_task_index: task_index, preview_task_name: task_name)
  end
end
