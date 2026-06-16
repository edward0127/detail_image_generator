require "test_helper"
require "nokogiri"
require "stringio"

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
    assert_equal 0, spacing
    assert_includes html, "tracked-grapheme"
    assert_includes html, "color: #F4EAD7"
    refute_match(/style="[^"]*"Microsoft YaHei"/, html)
  end

  test "renders font face for global font assets" do
    project = ImageProject.create!(name: "Renderer HTML")
    font = create_global_font_asset("BrandGlobal.woff2")
    warnings = []

    html = ImageProjects::Renderer.new(project).send(:build_html, text_task("BrandGlobal"), default_dimensions, "png", warnings, [])

    assert_includes html, %(font-family: "global_font_#{font.id}")
    assert_includes html, %(format("woff2"))
    refute warnings.any? { |warning| warning.include?("was not uploaded") }
  end

  test "renders font face for project-specific legacy font assets" do
    project = ImageProject.create!(name: "Renderer HTML")
    font = create_project_font_asset(project, "BrandProject.ttf")
    warnings = []

    html = ImageProjects::Renderer.new(project).send(:build_html, text_task("BrandProject.ttf"), default_dimensions, "png", warnings, [])

    assert_includes html, %(font-family: "project_font_#{font.id}")
    assert_includes html, %(format("truetype"))
    refute warnings.any? { |warning| warning.include?("was not uploaded") }
  end

  test "fileless global font records warn and use fallback font" do
    project = ImageProject.create!(name: "Renderer HTML")
    font = GlobalFontAsset.create!(
      name: "FilelessBrand.ttf",
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless("FilelessBrand.ttf")
    )
    warnings = []

    html = ImageProjects::Renderer.new(project).send(:build_html, text_task("FilelessBrand.ttf"), default_dimensions, "png", warnings, [])

    refute_includes html, %(font-family: "global_font_#{font.id}")
    assert_includes html, "font-family: Arial, &quot;Microsoft YaHei&quot;"
    assert warnings.any? { |warning| warning.include?("Font \"FilelessBrand.ttf\" was not uploaded.") }
  end

  test "normal text layer renders inline bold span" do
    html = render_html_for_text_layer(
      "text" => "**DESIGN** HIGHLIGHTS",
      "fontSize" => 40,
      "letterSpacingRatio" => 0,
      "autoWrap" => false
    )
    spans = Nokogiri::HTML(html).css(".layer span")

    assert spans.any? { |span| span.text == "DESIGN" && span["style"].to_s.include?("font-weight: 700") }
    assert spans.any? { |span| span.text == " HIGHLIGHTS" && span["style"].blank? }
    refute_includes html, "**DESIGN**"
  end

  test "normal text layer renders inline italic span" do
    html = render_html_for_text_layer(
      "text" => "This is *important*",
      "fontSize" => 40,
      "letterSpacingRatio" => 0,
      "autoWrap" => false
    )

    assert Nokogiri::HTML(html).css(".layer span").any? { |span| span.text == "important" && span["style"].to_s.include?("font-style: italic") }
  end

  test "plain text still renders without inline spans" do
    html = render_html_for_text_layer(
      "text" => "DESIGN HIGHLIGHTS",
      "fontSize" => 40,
      "letterSpacingRatio" => 0,
      "autoWrap" => false
    )

    assert_equal "DESIGN HIGHLIGHTS", Nokogiri::HTML(html).css(".layer").first.text
    refute_includes html, "tracked-grapheme"
    refute_match(/<span[^>]*>DESIGN/, html)
  end

  test "user html is escaped not rendered" do
    html = render_html_for_text_layer(
      "text" => "**<script>alert(1)</script>**",
      "fontSize" => 40,
      "letterSpacingRatio" => 0,
      "autoWrap" => false
    )

    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute_includes html, "<script>alert(1)</script>"
  end

  test "whole layer bold still works" do
    html = render_html_for_text_layer("text" => "DESIGN HIGHLIGHTS", "bold" => true)

    assert_includes text_layer_style(html), "font-weight: 700"
  end

  test "whole layer italic still works" do
    html = render_html_for_text_layer("text" => "DESIGN HIGHLIGHTS", "italic" => true)

    assert_includes text_layer_style(html), "font-style: italic"
  end

  test "inline bold combines with layer level defaults safely" do
    html = render_html_for_text_layer(
      "text" => "**DESIGN** HIGHLIGHTS",
      "italic" => true,
      "fontSize" => 40,
      "letterSpacingRatio" => 0,
      "autoWrap" => false
    )

    assert_includes text_layer_style(html), "font-style: italic"
    assert Nokogiri::HTML(html).css(".layer span").any? { |span| span.text == "DESIGN" && span["style"].to_s.include?("font-weight: 700") }
  end

  test "centered title with inline bold uses deterministic grapheme tracking" do
    html = render_html_for_text_layer(
      "text" => "**DESIGN** HIGHLIGHTS",
      "fontSize" => 72,
      "letterSpacingRatio" => 0.05,
      "maxWidth" => 1650,
      "autoWrap" => false,
      "x" => "center",
      "align" => "center"
    )
    graphemes = tracked_graphemes(html)

    assert_includes html, "tracked-grapheme"
    refute_includes html, "**"
    assert_equal "DESIGNHIGHLIGHTS", graphemes.map(&:text).join
    assert graphemes.first(6).all? { |node| node["style"].include?("font-weight: 700") }
    assert graphemes.drop(6).all? { |node| node["style"].exclude?("font-weight: 700") }
    assert_includes text_layer_style(html), "letter-spacing: 0px"

    renderer = ImageProjects::Renderer.new(ImageProject.create!(name: "Metrics"))
    assert_equal(
      renderer.send(:estimated_single_line_text_metrics, "DESIGN HIGHLIGHTS", 72),
      renderer.send(:estimated_single_line_text_metrics, "**DESIGN** HIGHLIGHTS", 72)
    )
  end

  test "short centered Chinese title with separators uses deterministic grapheme tracking" do
    html = render_html_for_text_layer(
      "text" => "\u8F7B\u900F\u30FB\u4FDD\u6E29 \u2022 \u968F\u884C",
      "fontSize" => 80,
      "letterSpacingMode" => "spread",
      "targetTextWidthRatio" => 0.78,
      "letterSpacingRatio" => 0.3,
      "maxWidth" => 1650,
      "autoWrap" => false,
      "x" => "center",
      "align" => "center"
    )
    style = text_layer_style(html)
    declarations = style_declarations(style)

    assert_includes declarations, "left: 50%"
    assert_includes declarations, "transform: translateX(-50%)"
    assert_includes declarations, "width: fit-content"
    refute_includes declarations, "width: 1650px"
    assert_includes declarations, "max-width: 1650px"
    assert_includes declarations, "text-align: center"
    assert_includes declarations, "white-space: pre"
    assert_includes declarations, "letter-spacing: 0px"
    refute_match(/margin-right:\s*-/, html)

    graphemes = tracked_graphemes(html)
    assert_equal "\u8F7B\u900F\u30FB\u4FDD\u6E29\u2022\u968F\u884C", graphemes.map(&:text).join
    assert_equal graphemes.size - 1, graphemes.count { |node| node["style"].include?("margin-right") }
    assert graphemes.any? { |node| margin_right(node) > 80 }, "expected collapsed whitespace around separators to add a controlled phrase gap"
  end

  test "legacy auto wrapped short centered title still uses deterministic grapheme tracking when it fits" do
    html = render_html_for_text_layer(
      "text" => "DESIGN DETAILS",
      "fontSize" => 72,
      "letterSpacingRatio" => 0.05,
      "maxWidth" => 1650,
      "autoWrap" => true,
      "x" => "center",
      "align" => "center"
    )
    declarations = style_declarations(text_layer_style(html))

    assert_includes declarations, "width: fit-content"
    assert_includes declarations, "max-width: 1650px"
    assert_includes declarations, "white-space: pre-wrap"
    assert_includes declarations, "letter-spacing: 0px"
    assert_equal "DESIGNDETAILS", tracked_graphemes(html).map(&:text).join
  end

  test "short centered English title uses deterministic grapheme tracking" do
    html = render_html_for_text_layer(
      "text" => "DESIGN \u2022 DETAILS",
      "fontSize" => 72,
      "letterSpacingRatio" => 0.05,
      "maxWidth" => 1650,
      "autoWrap" => false,
      "x" => "center",
      "align" => "center"
    )
    style = text_layer_style(html)
    declarations = style_declarations(style)

    assert_includes declarations, "left: 50%"
    assert_includes declarations, "transform: translateX(-50%)"
    assert_includes declarations, "width: fit-content"
    refute_includes declarations, "width: 1650px"
    assert_includes declarations, "max-width: 1650px"
    assert_includes declarations, "letter-spacing: 0px"
    refute_match(/margin-right:\s*-/, html)

    graphemes = tracked_graphemes(html)
    assert_equal "DESIGN\u2022DETAILS", graphemes.map(&:text).join
    assert_in_delta 3.6, margin_right(graphemes.first), 0.001
    assert graphemes.any? { |node| margin_right(node) > 20 }, "expected spaces around separator to become controlled phrase gaps"
  end

  test "long wrapping centered body keeps configured block width" do
    body = "This centered body copy is intentionally long enough to behave like paragraph text. It should wrap inside the configured text block instead of shrinking to the visible line width."
    html = render_html_for_text_layer(
      "text" => body,
      "fontSize" => 42,
      "letterSpacingRatio" => 0.02,
      "lineHeightRatio" => 1.6,
      "maxWidth" => 1188,
      "autoWrap" => true,
      "x" => "center",
      "align" => "center"
    )
    style = text_layer_style(html)
    declarations = style_declarations(style)

    assert_includes declarations, "left: 50%"
    assert_includes declarations, "transform: translateX(-50%)"
    assert_includes declarations, "width: 1188px"
    assert_includes declarations, "max-width: 1188px"
    assert_includes declarations, "text-align: center"
    assert_includes declarations, "white-space: pre-wrap"
    refute_includes declarations, "width: fit-content"
    refute_match(/margin-right: -[\d.]+px/, html)
    refute_includes html, "tracked-grapheme"
    assert_in_delta 0.84, style.match(/letter-spacing: ([\d.]+)px/)[1].to_f, 0.001
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

  private

  def create_global_font_asset(name)
    asset = GlobalFontAsset.create!(
      name: name,
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    asset.file.attach(io: StringIO.new("font data"), filename: name, content_type: "font/#{File.extname(name).delete(".")}")
    asset
  end

  def create_project_font_asset(project, name)
    asset = project.font_assets.create!(
      name: name,
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    asset.file.attach(io: StringIO.new("font data"), filename: name, content_type: "font/#{File.extname(name).delete(".")}")
    asset
  end

  def text_task(font)
    {
      "targetName" => "Font Face",
      "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FFFFFF", "transparent" => false },
      "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
      "layers" => [
        {
          "id" => "layer1",
          "name" => "Title",
          "type" => "text",
          "text" => "Title",
          "font" => font,
          "fontSize" => 80,
          "color" => "#1F1F1F",
          "letterSpacingRatio" => 0,
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
  end

  def default_dimensions
    {
      canvas_width: 1650,
      canvas_height: 2480,
      target_width: 1650,
      target_height: 2480,
      scale_x: 1,
      scale_y: 1
    }
  end

  def render_html_for_text_layer(overrides)
    project = ImageProject.create!(name: "Renderer HTML")
    task = {
      "targetName" => "Title Centering",
      "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FFFFFF", "transparent" => false },
      "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
      "layers" => [
        {
          "id" => "layer1",
          "name" => "Title",
          "type" => "text",
          "text" => "Title",
          "font" => "",
          "fontSize" => 80,
          "color" => "#1F1F1F",
          "letterSpacingRatio" => 0,
          "lineHeightRatio" => 1.2,
          "maxWidth" => 1650,
          "autoWrap" => false,
          "bold" => false,
          "italic" => false,
          "x" => "center",
          "y" => 200,
          "align" => "center",
          "opacity" => 1
        }.merge(overrides)
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

    ImageProjects::Renderer.new(project).send(:build_html, task, dimensions, "png", [], [])
  end

  def text_layer_style(html)
    html.match(/<div class="layer" style="([^"]+)"/)[1]
  end

  def style_declarations(style)
    style.split(";").map(&:strip)
  end

  def tracked_graphemes(html)
    Nokogiri::HTML(html).css(".tracked-grapheme")
  end

  def margin_right(node)
    match = node["style"].to_s.match(/margin-right: ([\d.]+)px/)
    match ? match[1].to_f : 0.0
  end
end
