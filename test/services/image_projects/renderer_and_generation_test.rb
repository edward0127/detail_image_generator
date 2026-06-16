require "test_helper"
require "base64"
require "stringio"
require "zip"

class ImageProjects::RendererAndGenerationTest < ActiveSupport::TestCase
  PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

  setup do
    skip "Chromium-compatible browser is not available" unless ImageProjects::Renderer.browser_path
  end

  test "renderer can generate an image file with configured output dimensions" do
    project = ImageProject.create!(name: "Render Project")
    attach_image_asset(project, "source.png")
    task = image_task("Render Output", "source", 120, 80)
    task["layers"] << text_layer("Missing Font Text", "MissingFont.ttf")

    result = ImageProjects::Renderer.new(project).render_final(task)

    assert File.exist?(result.path)
    assert_equal [ 120, 80 ], FastImage.size(result.path)
    assert_empty result.errors
    assert result.warnings.any? { |warning| warning.include?("MissingFont.ttf") }
  ensure
    File.delete(result.path) if defined?(result) && result&.path.present? && File.exist?(result.path)
  end

  test "preview current task creates a scaled preview image" do
    project = ImageProject.create!(name: "Preview Project")
    task = text_task("Preview Output", 120, 80, text: "Preview Text")

    result = ImageProjects::Renderer.new(project).render_preview(task, scale: 0.5)

    assert File.exist?(result.path)
    assert_equal [ 60, 40 ], FastImage.size(result.path)
    assert_empty result.errors
  ensure
    File.delete(result.path) if defined?(result) && result&.path.present? && File.exist?(result.path)
  end

  test "renderer supports Chinese English and mixed text" do
    project = ImageProject.create!(name: "Mixed Text Project")

    [
      "留住温度 延长适饮",
      "Premium Ceramic Cup",
      "DESIGN HIGHLIGHTS 如何让设计为饮用体验锦上添花"
    ].each do |text|
      result = nil
      begin
        result = ImageProjects::Renderer.new(project).render_final(text_task("Text Output", 220, 120, text: text))

        assert File.exist?(result.path)
        assert_equal [ 220, 120 ], FastImage.size(result.path)
        assert_empty result.errors
      ensure
        File.delete(result.path) if result&.path.present? && File.exist?(result.path)
      end
    end
  end

  test "centered tracked title renders visually centered in final png" do
    skip "ruby-vips is not available" unless vips_available?

    project = ImageProject.create!(name: "Tracked Title Raster Project")
    task = {
      "targetName" => "Tracked Title Raster",
      "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#3A1612", "transparent" => false },
      "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
      "layers" => [
        {
          "id" => "layer1",
          "name" => "Title",
          "type" => "text",
          "text" => "\u7559\u4F4F\u6E29\u5EA6 \u5EF6\u957F\u9002\u996E",
          "font" => "GenWanMinTW-Light.ttf",
          "fontSize" => 80,
          "color" => "#F4EAD7",
          "letterSpacingRatio" => 0.65,
          "lineHeightRatio" => 1.2,
          "maxWidth" => 1650,
          "autoWrap" => false,
          "bold" => false,
          "italic" => false,
          "x" => "center",
          "y" => 200,
          "align" => "center",
          "opacity" => 1
        }
      ]
    }

    result = ImageProjects::Renderer.new(project).render_final(task)
    assert_empty result.errors

    bounds = visible_title_bounds(result.path, y: 140, height: 260)
    visible_center = (bounds[:left] + bounds[:right]) / 2.0
    canvas_center = result.width / 2.0

    assert_in_delta canvas_center, visible_center, 5.0
  ensure
    File.delete(result.path) if defined?(result) && result&.path.present? && File.exist?(result.path)
  end

  test "missing Chinese font warns and falls back without crashing" do
    project = ImageProject.create!(name: "Missing Chinese Font Project")
    task = text_task("Chinese Font Fallback", 220, 120, text: "设计亮点", font: "不存在字体.ttf")

    result = ImageProjects::Renderer.new(project).render_final(task)

    assert File.exist?(result.path)
    assert_empty result.errors
    assert result.warnings.any? { |warning| warning.include?("不存在字体.ttf") && warning.include?("fallback font") }
  ensure
    File.delete(result.path) if defined?(result) && result&.path.present? && File.exist?(result.path)
  end

  test "batch generation creates multiple files and zip contains generated files" do
    project = ImageProject.create!(name: "Batch Project")
    project.update_config!(
      "projectName" => "Batch Project",
      "canvasDefaults" => { "width" => 80, "height" => 50, "backgroundColor" => "#FFFFFF", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [
        text_task("Front", 80, 50),
        text_task("Back", 80, 50)
      ]
    )

    job = ImageProjects::GenerationRunner.call(project)

    assert_equal "completed", job.status
    assert_equal 2, job.generated_images.count
    assert job.generated_images.all? { |image| image.file.attached? }
    assert_equal [ 80, 50 ], FastImage.size(StringIO.new(job.generated_images.first.file.download))

    entries = zip_entries(job.zip_file.download)
    assert_includes entries, "Front.png"
    assert_includes entries, "Back.png"
  end

  test "batch generation zip uses P1 and P2 target names with task formats" do
    project = ImageProject.create!(name: "P1 P2 Zip Project")
    p1 = text_task("P1", 80, 50)
    p2 = text_task("P2", 80, 50)
    p2["output"]["format"] = "jpg"
    project.update_config!(
      "projectName" => "P1 P2 Zip Project",
      "canvasDefaults" => { "width" => 80, "height" => 50, "backgroundColor" => "#FFFFFF", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [ p1, p2 ]
    )

    job = ImageProjects::GenerationRunner.call(project)

    assert_equal "completed", job.status
    assert_equal [ "P1.png", "P2.jpg" ], zip_entries(job.zip_file.download).sort
  end

  test "batch generation keeps only the latest job and purges prior generated blobs" do
    project = ImageProject.create!(name: "Generation Retention Project")
    project.update_config!(
      "projectName" => "Generation Retention Project",
      "canvasDefaults" => { "width" => 80, "height" => 50, "backgroundColor" => "#FFFFFF", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [
        text_task("P1", 80, 50),
        text_task("P2", 80, 50)
      ]
    )

    old_job = ImageProjects::GenerationRunner.call(project)
    old_job_id = old_job.id
    old_generated_ids = old_job.generated_images.pluck(:id)
    old_blobs = old_job.generated_images.map { |image| image.file.blob } + [ old_job.zip_file.blob ]

    new_job = ImageProjects::GenerationRunner.call(project)

    assert_equal "completed", new_job.status
    assert_equal [ new_job.id ], project.image_generation_jobs.pluck(:id)
    refute ImageGenerationJob.exists?(old_job_id)
    old_generated_ids.each do |generated_id|
      refute GeneratedImage.exists?(generated_id)
    end
    old_blobs.each do |blob|
      refute ActiveStorage::Blob.exists?(blob.id)
      refute blob.service.exist?(blob.key)
    end
    assert_equal [ "P1.png", "P2.png" ], zip_entries(new_job.zip_file.download).sort
  end

  test "current task generation creates only the selected task and zip entry" do
    project = ImageProject.create!(name: "Current Task Project")
    project.update_config!(
      "projectName" => "Current Task Project",
      "canvasDefaults" => { "width" => 80, "height" => 50, "backgroundColor" => "#FFFFFF", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [
        text_task("Front", 80, 50),
        text_task("Back", 80, 50)
      ]
    )

    job = ImageProjects::GenerationRunner.call(project, task_indexes: [ 1 ])

    assert_equal "completed", job.status
    assert_equal [ "Back" ], job.generated_images.pluck(:target_name)
    assert_equal [ "Back.png" ], zip_entries(job.zip_file.download)
  end

  test "current task generation succeeds for P1 when P2 image is missing" do
    project = ImageProject.create!(name: "Current P1 Project")
    attach_image_asset(project, "p1.png")
    project.update_config!(
      "projectName" => "Current P1 Project",
      "canvasDefaults" => { "width" => 80, "height" => 50, "backgroundColor" => "#FFFFFF", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [
        image_task("P1", "p1", 80, 50),
        image_task("P2", "P2", 80, 50)
      ]
    )

    job = ImageProjects::GenerationRunner.call(project, task_indexes: [ 0 ])

    assert_equal "completed", job.status
    assert_equal [ "P1" ], job.generated_images.pluck(:target_name)
    assert_empty job.generated_images.first.errors_list
    assert_equal [ "P1.png" ], zip_entries(job.zip_file.download)
  end

  test "all task generation continues when P2 image is missing" do
    project = ImageProject.create!(name: "All Tasks Missing P2 Project")
    attach_image_asset(project, "p1.png")
    project.update_config!(
      "projectName" => "All Tasks Missing P2 Project",
      "canvasDefaults" => { "width" => 80, "height" => 50, "backgroundColor" => "#FFFFFF", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [
        image_task("P1", "p1", 80, 50),
        image_task("P2", "P2", 80, 50)
      ]
    )

    job = ImageProjects::GenerationRunner.call(project)

    assert_equal "completed_with_errors", job.status
    assert_empty job.generated_images.find_by(target_name: "P1").errors_list
    assert job.generated_images.find_by(target_name: "P2").errors_list.first.include?("source image \"P2\" was not found")
    assert_equal [ "P1.png" ], zip_entries(job.zip_file.download)
  end

  test "missing image records task error but does not crash batch generation" do
    project = ImageProject.create!(name: "Missing Image Project")
    project.update_config!(
      "projectName" => "Missing Image Project",
      "canvasDefaults" => { "width" => 80, "height" => 50, "backgroundColor" => "#FFFFFF", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [
        image_task("Missing Asset", "does-not-exist", 80, 50),
        text_task("Still Runs", 80, 50)
      ]
    )

    job = ImageProjects::GenerationRunner.call(project)

    assert_equal "completed_with_errors", job.status
    assert_equal 2, job.generated_images.count
    assert job.generated_images.find_by(target_name: "Missing Asset").errors_list.first.include?("was not found")
    assert_empty job.generated_images.find_by(target_name: "Still Runs").errors_list
    assert_equal [ "Still_Runs.png" ], zip_entries(job.zip_file.download)
  end

  private

  def attach_image_asset(project, name)
    tempfile = Tempfile.new([ "source", ".png" ])
    tempfile.binmode
    tempfile.write(Base64.decode64(PNG_1X1))
    tempfile.rewind

    asset = project.image_assets.create!(
      name: name,
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name),
      width: 1,
      height: 1
    )
    File.open(tempfile.path, "rb") do |file|
      asset.file.attach(io: file, filename: name, content_type: "image/png")
    end
    asset
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  def image_task(target_name, image_name, width, height)
    {
      "targetName" => target_name,
      "canvas" => { "width" => width, "height" => height, "backgroundColor" => "#FFFFFF", "transparent" => false },
      "output" => { "width" => width, "height" => height, "format" => "png" },
      "layers" => [
        {
          "id" => "layer0",
          "name" => "Image",
          "type" => "image",
          "imageName" => image_name,
          "width" => width,
          "height" => height,
          "x" => "center",
          "y" => 0,
          "fit" => "cover",
          "opacity" => 1
        }
      ]
    }
  end

  def text_task(target_name, width, height, text: "Generated Text", font: "")
    {
      "targetName" => target_name,
      "canvas" => { "width" => width, "height" => height, "backgroundColor" => "#FFFFFF", "transparent" => false },
      "output" => { "width" => width, "height" => height, "format" => "png" },
      "layers" => [ text_layer(text, font) ]
    }
  end

  def text_layer(text, font)
    {
      "id" => "layer1",
      "name" => "Text",
      "type" => "text",
      "text" => text,
      "font" => font,
      "fontSize" => 16,
      "color" => "#1F1F1F",
      "letterSpacingRatio" => 0.05,
      "lineHeightRatio" => 1.2,
      "maxWidth" => 70,
      "autoWrap" => true,
      "bold" => false,
      "italic" => false,
      "x" => "center",
      "y" => 12,
      "align" => "center",
      "opacity" => 1
    }
  end

  def zip_entries(bytes)
    entries = []
    Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
      entries = zip.map(&:name)
    end
    entries
  end

  def vips_available?
    require "vips"
    true
  rescue LoadError
    false
  end

  def visible_title_bounds(path, y:, height:)
    image = Vips::Image.new_from_file(path, access: :sequential)
    region = image.crop(0, y, image.width, height)
    pixels = region.write_to_memory
    bands = region.bands
    left = image.width
    right = -1

    height.times do |row|
      image.width.times do |column|
        offset = (row * image.width + column) * bands
        red = pixels.getbyte(offset)
        green = pixels.getbyte(offset + 1)
        blue = pixels.getbyte(offset + 2)
        next unless red + green + blue > 250

        left = column if column < left
        right = column if column > right
      end
    end

    assert_operator right, :>=, left, "expected title foreground pixels in rendered PNG"
    { left: left, right: right }
  end
end
