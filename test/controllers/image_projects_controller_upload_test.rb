require "test_helper"

class ImageProjectsControllerUploadTest < ActionDispatch::IntegrationTest
  class ExplodingOriginalFilename
    def original_filename
      raise "original_filename should not be called"
    end
  end

  setup do
    @tempfiles = []
  end

  teardown do
    @tempfiles.each do |tempfile|
      tempfile.close
      tempfile.unlink
    end
  end

  test "upload images ignores blank hidden value and uploads one file" do
    project = create_project
    upload = uploaded_file("p1.png", "image/png")

    assert_difference -> { project.image_assets.count }, 1 do
      post upload_images_image_project_path(project), params: { images: [ "", upload ] }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "1 image(s) uploaded."

    asset = project.image_assets.last
    assert_equal "p1.png", asset.name
    assert_equal "p1", asset.alias_name
  end

  test "upload images accepts multiple uploaded files" do
    project = create_project
    uploads = [
      uploaded_file("p1.png", "image/png"),
      uploaded_file("p2.jpg", "image/jpeg")
    ]

    assert_difference -> { project.image_assets.count }, 2 do
      post upload_images_image_project_path(project), params: { images: uploads }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal [ "p1.png", "p2.jpg" ], project.image_assets.order(:name).pluck(:name)
  end

  test "upload images defaults duplicate filename match name to clean base" do
    project = create_project
    upload = uploaded_file("p1(1).png", "image/png")

    assert_difference -> { project.image_assets.count }, 1 do
      post upload_images_image_project_path(project), params: { images: [ upload ] }
    end

    assert_equal "p1", project.image_assets.last.alias_name
  end

  test "upload images skips unsupported extensions safely" do
    project = create_project
    upload = uploaded_file("product.gif", "image/gif")

    assert_no_difference -> { project.image_assets.count } do
      post upload_images_image_project_path(project), params: { images: [ upload ] }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "0 image(s) uploaded."
    assert_includes response.body, "Skipped unsupported files: product.gif"
  end

  test "upload fonts ignores blank hidden value and uploads one file" do
    project = create_project
    upload = uploaded_file("brand.ttf", "font/ttf")

    assert_difference -> { project.font_assets.count }, 1 do
      post upload_fonts_image_project_path(project), params: { fonts: [ "", upload ] }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "1 font(s) uploaded."
    assert_equal "brand.ttf", project.font_assets.last.name
    assert_equal "brand", project.font_assets.last.alias_name
  end

  test "upload fonts accepts multiple uploaded files" do
    project = create_project
    uploads = [
      uploaded_file("brand.ttf", "font/ttf"),
      uploaded_file("display.otf", "font/otf")
    ]

    assert_difference -> { project.font_assets.count }, 2 do
      post upload_fonts_image_project_path(project), params: { fonts: uploads }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal [ "brand.ttf", "display.otf" ], project.font_assets.order(:name).pluck(:name)
  end

  test "project page shows imported task names workflow actions and collapsed advanced sections" do
    project = create_project
    project.update_config!(
      "projectName" => "Uploads",
      "canvasDefaults" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [
        task_config("P1"),
        task_config("P2")
      ]
    )

    get image_project_path(project)

    assert_response :success
    assert_select ".task-title", text: "P1"
    assert_select ".task-title", text: "P2"
    assert_includes response.body, "Import Excel"
    assert_includes response.body, "Upload Images"
    assert_includes response.body, "Upload Fonts"
    assert_select "form.workflow-form[data-upload-reminder='true']", count: 3
    assert_select "form[data-upload-kind='excel'][data-upload-pending-label='Import Excel Now']"
    assert_select "form[data-upload-kind='images'][data-upload-action='Upload'][data-upload-singular='Image'][data-upload-plural='Images']"
    assert_select "form[data-upload-kind='fonts'][data-upload-action='Upload'][data-upload-singular='Font'][data-upload-plural='Fonts']"
    assert_select ".upload-reminder-message[hidden][data-upload-reminder-message]", text: "File selected but not uploaded yet.", count: 3
    assert_includes response.body, "Preview P1"
    assert_includes response.body, "Generate P1"
    assert_includes response.body, "Generate All Images"
    assert_includes response.body, "Selected Image: <strong>P1</strong>"
    assert_includes response.body, "Preview is scaled for browser display."
    assert_includes response.body, "Final output size: <strong>1650 x 2480</strong>"
    assert_select "select[name='task[layoutMode]'] option[selected='selected'][value='strict']", text: "Strict Excel values"
    assert_includes response.body, "Imported 2 tasks:"
    assert_includes response.body, "Danger Zone"
    assert_includes response.body, "Delete this project and all uploaded/generated files? This cannot be undone."
    assert_select "details.advanced-panel summary", text: "Advanced JSON"
    assert_select "details.advanced-panel[open]", count: 0
    assert_select "details.layers-panel summary", text: /Fine-tune Layers/
    assert_select "details.layers-panel[open]", count: 0
  end

  test "project page shows readiness checklist for matched and missing assets" do
    project = create_project
    project.image_assets.create!(
      name: "p1.png",
      alias_name: "p1",
      normalized_name: "p1",
      width: 1650,
      height: 2480
    )
    p1 = task_config("P1")
    p1["layers"] = [
      { "id" => "layer0", "type" => "image", "imageName" => "p1" },
      { "id" => "layer1", "type" => "text", "font" => "GenWanMinTW-Light.ttf" }
    ]
    p2 = task_config("P2")
    p2["layers"] = [
      { "id" => "layer0", "type" => "image", "imageName" => "P2" },
      { "id" => "layer1", "type" => "text", "font" => "AlibabaPuHuiTi-3-55-Regular" }
    ]
    project.update_config!(
      "projectName" => "Uploads",
      "canvasDefaults" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [ p1, p2 ]
    )

    get image_project_path(project)

    assert_response :success
    assert_includes response.body, "Imported 2 tasks:"
    assert_includes response.body, "p1 matched to p1.png"
    assert_includes response.body, "P2 missing"
    assert_includes response.body, "Font &quot;GenWanMinTW-Light.ttf&quot; was not uploaded. A fallback font was used, so the generated image may not visually match the expected design."
    assert_includes response.body, "Font &quot;AlibabaPuHuiTi-3-55-Regular&quot; was not uploaded. A fallback font was used, so the generated image may not visually match the expected design."
    assert_includes response.body, "Why does my output look different?"
    assert_includes response.body, "upload the correct font files"
    assert_includes response.body, "check Excel Match Name"
    assert_includes response.body, "preview is scaled"
    assert_includes response.body, "design-friendly mode may adjust visual layout"
  end

  test "saving editor preserves spread title settings and applies P1 off-white default color" do
    project = create_project
    project.update_config!(
      "projectName" => "Uploads",
      "canvasDefaults" => { "width" => 1650, "height" => 2480, "backgroundColor" => "transparent", "transparent" => true, "outputFormat" => "png" },
      "tasks" => [ task_config("P1") ]
    )

    patch image_project_path(project), params: {
      task_index: 0,
      image_project: { name: "Uploads" },
      task: {
        targetName: "P1",
        layoutMode: "design",
        canvas: { width: "1650", height: "2480", backgroundColor: "transparent", transparent: "1" },
        output: { width: "1650", height: "2480", format: "png" }
      },
      layers: {
        "0" => {
          id: "layer0",
          name: "Main Image",
          type: "image",
          imageName: "p1",
          width: "1650",
          height: "2480",
          fit: "cover",
          x: "center",
          y: "0",
          opacity: "1"
        },
        "1" => {
          id: "layer1",
          name: "Title",
          type: "text",
          text: "留住温度 延长适饮",
          font: "GenWanMinTW-Light.ttf",
          fontSize: "80",
          color: "",
          letterSpacingRatio: "0.65",
          lineHeightRatio: "1.2",
          maxWidth: "1650",
          autoWrap: "1",
          bold: "0",
          italic: "0",
          align: "center",
          letterSpacingMode: "spread",
          targetTextWidthRatio: "0.78",
          x: "center",
          y: "200",
          opacity: "1",
          notes: ""
        }
      }
    }

    assert_redirected_to image_project_path(project, task_index: 0)
    config = project.reload.config_hash
    title = config.dig("tasks", 0, "layers", 1)
    assert_equal "design", config["layoutMode"]
    assert_equal "#F4EAD7", title["color"]
    assert_equal "spread", title["letterSpacingMode"]
    assert_in_delta 0.78, title["targetTextWidthRatio"], 0.001
  end

  test "project index shows delete action" do
    project = create_project

    get image_projects_path

    assert_response :success
    assert_includes response.body, project.name
    assert_includes response.body, "Delete this project and all uploaded/generated files? This cannot be undone."
  end

  test "delete project route removes the project" do
    project = create_project

    assert_difference -> { ImageProject.count }, -1 do
      delete image_project_path(project)
    end

    assert_redirected_to image_projects_path
    refute ImageProject.exists?(project.id)
  end

  test "project page shows image and font asset match name controls" do
    project = create_project
    image = project.image_assets.create!(
      name: "Weixin Image_20260610.png",
      alias_name: "p1",
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless("Weixin Image_20260610.png"),
      width: 1650,
      height: 2480
    )
    font = project.font_assets.create!(
      name: "GenWanMinTW-Light.ttf",
      alias_name: "GenWanMinTW-Light",
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless("GenWanMinTW-Light.ttf")
    )

    get image_project_path(project)

    assert_response :success
    assert_includes response.body, image.name
    assert_includes response.body, "Dimensions: 1650 x 2480"
    assert_includes response.body, font.name
    assert_includes response.body, "Excel Match Name"
    assert_includes response.body, "If Excel says p1, this field should be p1."
    assert_select "input[name='image_asset[alias_name]'][value='p1']"
    assert_select "input[name='font_asset[alias_name]'][value='GenWanMinTW-Light']"
  end

  test "project page shows clear task-level missing image status" do
    project = create_project
    task = task_config("P2")
    task["layers"] = [
      {
        "id" => "layer0",
        "name" => "Main Image",
        "type" => "image",
        "imageName" => "P2",
        "width" => 600,
        "height" => 600,
        "x" => "center",
        "y" => 500,
        "fit" => "contain",
        "opacity" => 1
      }
    ]
    project.update_config!(
      "projectName" => "Uploads",
      "canvasDefaults" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [ task ]
    )

    get image_project_path(project)

    assert_response :success
    assert_includes response.body, "missing image"
    assert_includes response.body, "Task P2 could not be generated because source image &quot;P2&quot; was not found."
  end

  test "upload with no selected file redirects with a clear alert" do
    project = create_project

    assert_no_difference -> { project.image_assets.count } do
      post upload_images_image_project_path(project), params: { images: [ "" ] }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "Image upload failed: Choose one or more files to upload."
  end

  test "upload ignores string nil and unsupported objects without reading original filename" do
    controller = ImageProjectsController.new
    controller.define_singleton_method(:params) do
      {
        images: [
          "",
          nil,
          "not a file",
          Object.new,
          ExplodingOriginalFilename.new
        ]
      }
    end

    assert_empty controller.send(:uploaded_files_for, :images)
  end

  test "upload normalizer accepts hash and parameters file collections" do
    hash_upload = uploaded_file("hash.png", "image/png")
    parameters_upload = uploaded_file("parameters.png", "image/png")
    controller = ImageProjectsController.new

    controller.define_singleton_method(:params) { { images: { "0" => "", "1" => hash_upload } } }
    assert_equal [ hash_upload ], controller.send(:uploaded_files_for, :images)

    controller.define_singleton_method(:params) do
      {
        images: ActionController::Parameters.new("0" => "", "1" => parameters_upload)
      }
    end
    assert_equal [ parameters_upload ], controller.send(:uploaded_files_for, :images)
  end

  private

  def create_project
    ImageProject.create!(name: "Uploads")
  end

  def uploaded_file(filename, content_type)
    tempfile = Tempfile.new([ File.basename(filename, ".*"), File.extname(filename) ])
    tempfile.binmode
    tempfile.write("test upload")
    tempfile.rewind
    @tempfiles << tempfile

    Rack::Test::UploadedFile.new(tempfile.path, content_type, true, original_filename: filename)
  end

  def task_config(target_name)
    {
      "targetName" => target_name,
      "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
      "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
      "layers" => []
    }
  end
end
