require "test_helper"

class ImageProjects::RendererHtmlTest < ActiveSupport::TestCase
  test "text layer style attributes are escaped and preserve text CSS" do
    project = ImageProject.create!(name: "Renderer HTML")
    task = {
      "targetName" => "P1",
      "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "transparent", "transparent" => true },
      "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
      "layers" => [
        {
          "id" => "layer1",
          "name" => "Title",
          "type" => "text",
          "text" => "留住温度 延长适饮",
          "font" => "MissingFont.ttf",
          "fontSize" => 80,
          "letterSpacingMode" => "spread",
          "targetTextWidthRatio" => 0.78,
          "letterSpacingRatio" => 0.65,
          "lineHeightRatio" => 1.2,
          "maxWidth" => 1650,
          "autoWrap" => true,
          "x" => "center",
          "y" => 200,
          "align" => "center",
          "opacity" => 1
        }
      ]
    }
    dimensions = {
      canvas_width: 1650,
      canvas_height: 2480,
      target_width: 1650,
      target_height: 2480,
      scale_x: 1,
      scale_y: 1
    }

    html = ImageProjects::Renderer.new(project).send(:build_html, task, dimensions, "png", [], [])

    assert_includes html, "font-family: Arial, &quot;Microsoft YaHei&quot;"
    assert_includes html, "font-size: 80px"
    assert_includes html, "text-align: center"
    spacing = html.match(/letter-spacing: ([\d.]+)px/)[1].to_f
    assert_operator spacing, :>, 40
    assert_includes html, "color: #F4EAD7"
    refute_match(/style="[^"]*"Microsoft YaHei"/, html)
  end

  test "design-friendly mode scales small centered ecommerce image before resolving body offset" do
    project = ImageProject.create!(name: "Renderer HTML")
    task = {
      "targetName" => "P2",
      "layoutMode" => "design",
      "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
      "output" => { "width" => 1650, "height" => 2480, "format" => "jpg" },
      "layers" => [
        { "id" => "layer0", "type" => "image", "imageName" => "P2", "width" => 600, "height" => 600, "x" => "center", "y" => 500 },
        { "id" => "layer1", "type" => "text", "text" => "Title", "fontSize" => 80, "maxWidth" => 1650, "x" => "center", "y" => 150 },
        { "id" => "layer2", "type" => "text", "text" => "Subtitle", "fontSize" => 40, "maxWidth" => 1650, "x" => "center", "relativeTo" => "layer1", "relativePosition" => "below" },
        { "id" => "layer3", "type" => "text", "text" => "Readable body copy wraps below the enlarged product image.", "fontSize" => 40, "maxWidth" => 1188, "lineHeightRatio" => 1.6, "autoWrap" => true, "x" => "center", "relativeTo" => "layer0", "relativePosition" => "below", "relativeOffset" => 120 }
      ]
    }
    dimensions = {
      canvas_width: 1650,
      canvas_height: 2480,
      target_width: 1650,
      target_height: 2480,
      scale_x: 1,
      scale_y: 1
    }

    renderer = ImageProjects::Renderer.new(project)
    layers = renderer.send(:prepared_layers_for_render, task, dimensions)
    image = layers.first
    resolved = renderer.send(:resolve_relative_layers, layers)
    body = resolved.last

    assert_equal 990, image["width"]
    assert_equal 990, image["height"]
    assert_equal 1610, body["y"]
  end

  test "project-level design mode scales image and normalizes long body layout when task omits mode" do
    project = ImageProject.create!(name: "Renderer HTML")
    project.update_config!(
      "projectName" => "Renderer HTML",
      "layoutMode" => "design",
      "tasks" => []
    )
    long_body = "双层陶瓷结构帮助热饮保持温度，圆润杯口贴合唇部，隐藏式杯盖减少热量散失，让每一次饮用都从容舒适，也让桌面陈列更显简洁精致。"
    task = {
      "targetName" => "P2",
      "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
      "output" => { "width" => 1650, "height" => 2480, "format" => "jpg" },
      "layers" => [
        { "id" => "layer0", "type" => "image", "imageName" => "P2", "width" => 600, "height" => 600, "x" => "center", "y" => 500 },
        { "id" => "layer1", "type" => "text", "text" => "设计亮点", "fontSize" => 80, "maxWidth" => 1650, "x" => "center", "y" => 150 },
        { "id" => "layer2", "type" => "text", "text" => "DESIGN HIGHLIGHTS", "fontSize" => 40, "maxWidth" => 1650, "x" => "center", "relativeTo" => "layer1", "relativePosition" => "below" },
        { "id" => "layer3", "type" => "text", "text" => long_body, "fontSize" => 40, "maxWidth" => 1650, "lineHeightRatio" => 1.2, "x" => "center", "relativeTo" => "layer0", "relativePosition" => "below", "relativeOffset" => 120 }
      ]
    }
    dimensions = {
      canvas_width: 1650,
      canvas_height: 2480,
      target_width: 1650,
      target_height: 2480,
      scale_x: 1,
      scale_y: 1
    }

    layers = ImageProjects::Renderer.new(project).send(:prepared_layers_for_render, task, dimensions)
    image = layers.first
    body = layers.last

    assert_equal 990, image["width"]
    assert_equal 990, image["height"]
    assert_equal 1188, body["maxWidth"]
    assert_equal 1.6, body["lineHeightRatio"]
    assert_equal true, body["autoWrap"]
    assert_equal "center", body["align"]
  end
end
