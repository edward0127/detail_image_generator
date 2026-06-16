require "test_helper"
require "base64"
require "stringio"

class ImageProjects::RenderInputSignatureTest < ActiveSupport::TestCase
  PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

  test "preview signatures are scoped to the selected task" do
    project = text_project([ "P1", "P2" ])

    p1_signature = ImageProjects::RenderInputSignature.preview_task(project, 0)
    p2_signature = ImageProjects::RenderInputSignature.preview_task(project, 1)

    refute_equal p1_signature, p2_signature
  end

  test "preview signature changes when selected task config changes" do
    project = text_project([ "P1" ])
    old_signature = ImageProjects::RenderInputSignature.preview_task(project, 0)

    config = project.config_hash
    config["tasks"][0]["layers"][0]["fontSize"] = 84
    project.update_config!(config)

    refute_equal old_signature, ImageProjects::RenderInputSignature.preview_task(project.reload, 0)
  end

  test "preview signature changes when matched source image blob changes" do
    project = image_project
    asset = attach_image_asset(project, "source.png", bytes: Base64.decode64(PNG_1X1))
    old_signature = ImageProjects::RenderInputSignature.preview_task(project, 0)

    asset.file.purge
    asset.file.attach(io: StringIO.new("replacement image"), filename: "source.png", content_type: "image/png")

    refute_equal old_signature, ImageProjects::RenderInputSignature.preview_task(project.reload, 0)
  end

  test "zip signature changes when matched font blob changes" do
    project = text_project([ "P1" ], font: "Brand")
    font = create_global_font_asset("Brand.ttf", bytes: "font-v1")
    old_signature = ImageProjects::RenderInputSignature.full_zip(project)

    font.file.purge
    font.file.attach(io: StringIO.new("font-v2"), filename: "Brand.ttf", content_type: "font/ttf")

    refute_equal old_signature, ImageProjects::RenderInputSignature.full_zip(project.reload)
  end

  test "full zip signature changes when any task config changes" do
    project = text_project([ "P1", "P2" ])
    old_signature = ImageProjects::RenderInputSignature.full_zip(project)

    config = project.config_hash
    config["tasks"][1]["layers"][0]["text"] = "Changed P2"
    project.update_config!(config)

    refute_equal old_signature, ImageProjects::RenderInputSignature.full_zip(project.reload)
  end

  private

  def text_project(names, font: "")
    project = ImageProject.create!(name: "Signature")
    project.update_config!(
      "projectName" => "Signature",
      "tasks" => names.map { |name| text_task(name, font: font) }
    )
    project
  end

  def image_project
    project = ImageProject.create!(name: "Signature Image")
    project.update_config!(
      "projectName" => "Signature Image",
      "tasks" => [
        {
          "targetName" => "P1",
          "canvas" => { "width" => 100, "height" => 100, "backgroundColor" => "#FFFFFF", "transparent" => false },
          "output" => { "width" => 100, "height" => 100, "format" => "png" },
          "layers" => [
            {
              "id" => "layer0",
              "name" => "Image",
              "type" => "image",
              "imageName" => "source",
              "width" => 100,
              "height" => 100,
              "x" => "center",
              "y" => 0,
              "fit" => "contain",
              "opacity" => 1
            }
          ]
        }
      ]
    )
    project
  end

  def text_task(target_name, font:)
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
          "font" => font,
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

  def attach_image_asset(project, name, bytes:)
    asset = project.image_assets.create!(
      name: name,
      alias_name: ImageProjects::AssetNameNormalizer.default_alias(name),
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name),
      width: 1,
      height: 1
    )
    asset.file.attach(io: StringIO.new(bytes), filename: name, content_type: "image/png")
    asset
  end

  def create_global_font_asset(name, bytes:)
    asset = GlobalFontAsset.create!(
      name: name,
      match_name: ImageProjects::AssetNameNormalizer.default_alias(name),
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    asset.file.attach(io: StringIO.new(bytes), filename: name, content_type: "font/#{File.extname(name).delete(".")}")
    asset
  end
end
