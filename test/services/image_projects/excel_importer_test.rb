require "test_helper"
require "zip"

class ImageProjects::ExcelImporterTest < ActiveSupport::TestCase
  test "size parser supports multiple formats" do
    assert_equal({ "width" => 1650, "height" => 2480 }, ImageProjects::ExcelParsers.parse_size("1650 × 2480 px"))
    assert_equal({ "width" => 1650, "height" => 2480 }, ImageProjects::ExcelParsers.parse_size("1650 x 2480 px"))
    assert_equal({ "width" => 1650, "height" => 2480 }, ImageProjects::ExcelParsers.parse_size("1650*2480px"))
    assert_equal({ "width" => 600, "height" => 600 }, ImageProjects::ExcelParsers.parse_size("600 × 600 px"))
  end

  test "color parser supports transparent Chinese color names and hex values" do
    transparent = ImageProjects::ExcelParsers.parse_color("透明")
    assert_equal "transparent", transparent.background_color
    assert_equal true, transparent.transparent

    assert_equal "#FFFFFF", ImageProjects::ExcelParsers.parse_color("白色").background_color
    assert_equal "#000000", ImageProjects::ExcelParsers.parse_color("黑色").background_color
    assert_equal "#FAFAF0", ImageProjects::ExcelParsers.parse_color("#fafaf0").background_color
    assert_equal "transparent", ImageProjects::ExcelParsers.parse_color("transparent").background_color
  end

  test "font size parser supports pt formats" do
    assert_in_delta 80, ImageProjects::ExcelParsers.parse_font_size("60 pt"), 0.01
    assert_in_delta 80, ImageProjects::ExcelParsers.parse_font_size("60pt"), 0.01
    assert_in_delta 40, ImageProjects::ExcelParsers.parse_font_size("30 pt"), 0.01
    assert_in_delta 40, ImageProjects::ExcelParsers.parse_font_size("30pt"), 0.01
    assert_equal 60, ImageProjects::ExcelParsers.parse_font_size("60px")
    assert_equal 60, ImageProjects::ExcelParsers.parse_font_size("60")
  end

  test "letter spacing notes distinguish generic ratio percentage and explicit spread width" do
    generic = {
      "name" => "Title",
      "text" => "Title Copy",
      "fontSize" => 80,
      "letterSpacingRatio" => 0,
      "x" => "center",
      "align" => "center"
    }
    explicit = generic.merge("letterSpacingRatio" => 0)
    spread = generic.merge("letterSpacingRatio" => 0)

    ImageProjects::ExcelParsers.apply_notes_to_text_layer!(generic, "\u5C06\u5B57\u4F53\u95F4\u8DDD\u62C9\u5F00")
    ImageProjects::ExcelParsers.apply_notes_to_text_layer!(explicit, "\u5B57\u8DDD\u62C9\u5F00\u81F3\u5B57\u53F7\u768430%")
    ImageProjects::ExcelParsers.apply_notes_to_text_layer!(spread, "spread text across 78% canvas width")

    assert_equal 0.3, generic["letterSpacingRatio"]
    refute generic.key?("letterSpacingMode")
    refute generic.key?("targetTextWidthRatio")
    assert_equal 0.3, explicit["letterSpacingRatio"]
    refute explicit.key?("letterSpacingMode")
    assert_equal "spread", spread["letterSpacingMode"]
    assert_in_delta 0.78, spread["targetTextWidthRatio"], 0.001
    assert_equal 0.3, spread["letterSpacingRatio"]
  end

  test "Chinese partial bold note converts matching word to inline bold" do
    layer = { "text" => "DESIGN HIGHLIGHTS", "bold" => false }

    ImageProjects::ExcelParsers.apply_notes_to_text_layer!(layer, "其中 DESIGN 这个单词加粗")

    assert_equal "**DESIGN** HIGHLIGHTS", layer["text"]
    assert_equal false, layer["bold"]
  end

  test "English partial bold note converts matching word to inline bold" do
    layer = { "text" => "DESIGN HIGHLIGHTS", "bold" => false }

    ImageProjects::ExcelParsers.apply_notes_to_text_layer!(layer, "make DESIGN bold")

    assert_equal "**DESIGN** HIGHLIGHTS", layer["text"]
    assert_equal false, layer["bold"]
  end

  test "generic whole layer bold notes still set bold flag" do
    all_bold = { "text" => "DESIGN HIGHLIGHTS", "bold" => false }
    text_bold = { "text" => "DESIGN HIGHLIGHTS", "bold" => false }

    ImageProjects::ExcelParsers.apply_notes_to_text_layer!(all_bold, "all bold")
    ImageProjects::ExcelParsers.apply_notes_to_text_layer!(text_bold, "make the text bold")

    assert_equal true, all_bold["bold"]
    assert_equal "DESIGN HIGHLIGHTS", all_bold["text"]
    assert_equal true, text_bold["bold"]
    assert_equal "DESIGN HIGHLIGHTS", text_bold["text"]
  end

  test "partial bold note with missing phrase preserves text without whole layer bold" do
    layer = { "text" => "DESIGN HIGHLIGHTS", "bold" => false }

    ImageProjects::ExcelParsers.apply_notes_to_text_layer!(layer, "make MATERIAL bold")

    assert_equal "DESIGN HIGHLIGHTS", layer["text"]
    assert_equal false, layer["bold"]
    assert_includes layer["notes"], "make MATERIAL bold"
  end

  test "partial bold note does not double wrap existing inline markup" do
    layer = { "text" => "**DESIGN** HIGHLIGHTS", "bold" => false }

    ImageProjects::ExcelParsers.apply_notes_to_text_layer!(layer, "DESIGN bold")

    assert_equal "**DESIGN** HIGHLIGHTS", layer["text"]
    assert_equal false, layer["bold"]
  end

  test "image reference parser extracts natural language references" do
    assert_equal "p1", ImageProjects::ExcelParsers.parse_image_reference("使用图片名为p1")
    assert_equal "P2", ImageProjects::ExcelParsers.parse_image_reference("使用图片名为P2")
    assert_equal "p1", ImageProjects::ExcelParsers.parse_image_reference("use image p1")
    assert_equal "P2", ImageProjects::ExcelParsers.parse_image_reference("use image named P2")
    assert_equal "p1", ImageProjects::ExcelParsers.parse_image_reference("image name: p1")
    assert_equal "P2", ImageProjects::ExcelParsers.parse_image_reference("source image: P2")
    assert_equal "P2", ImageProjects::ExcelParsers.parse_image_reference("P2")
  end

  test "position parser supports top-distance descriptions" do
    assert_equal({ "x" => "center", "y" => 180 }, ImageProjects::ExcelParsers.parse_position("距离顶部 180 px"))
    assert_equal({ "x" => "center", "y" => 220 }, ImageProjects::ExcelParsers.parse_position("距离画布顶端 220 px"))
    assert_equal({ "x" => "center", "y" => 200 }, ImageProjects::ExcelParsers.parse_position("top 200 px"))
    assert_equal({ "x" => "center", "y" => 500 }, ImageProjects::ExcelParsers.parse_position("500 px from canvas top"))
  end

  test "position parser supports bilingual relative descriptions" do
    chinese = ImageProjects::ExcelParsers.parse_position("在图层0下面距离 120 px")
    english = ImageProjects::ExcelParsers.parse_position("120 px below layer 0")

    assert_equal "layer0", chinese["relativeTo"]
    assert_equal 120, chinese["relativeOffset"]
    assert_equal "layer0", english["relativeTo"]
    assert_equal 120, english["relativeOffset"]
  end

  test "unknown position descriptions are preserved" do
    parsed = ImageProjects::ExcelParsers.parse_position("靠近杯身左侧")

    assert_equal "靠近杯身左侧", parsed["notes"]
    assert parsed["warnings"].first.include?("was not parsed")
  end

  test "importer reads xlsx and converts rows into JSON config" do
    project = ImageProject.create!(name: "Import Test")
    path = Rails.root.join("tmp", "p1_p2_import_test.xlsx")
    write_xlsx(path, [
      [ "targetName", "canvasSize", "background", "imageName", "title", "font", "fontSize", "position", "notes", "format" ],
      [ "P1", "1650 × 2480 px", "透明", "使用图片名为p1", "留住温度 延长适饮", "Gen Wan Min TW Light.ttf", "60 pt", "距离顶部 200 px", "字距拉开至字号的30% 加粗", "png" ],
      [ "P2", "600 x 600 px", "白色", "use image named P2", "Second", "Gen_Wan-Min-TW-Light.ttf", "30pt", "图层1下方居中", "将字体间距拉开", "jpg" ]
    ])

    config = ImageProjects::ExcelImporter.call(project, path)
    tasks = config["tasks"]

    assert_equal 2, tasks.size
    assert_equal "P1", tasks.first["targetName"]
    assert_equal "P2", tasks.second["targetName"]
    assert_equal "p1", tasks.first.dig("layers", 0, "imageName")
    assert_equal "P2", tasks.second.dig("layers", 0, "imageName")
    assert_equal true, tasks.first.dig("canvas", "transparent")
    assert_equal "design", config["layoutMode"]
    assert_equal "design", tasks.first["layoutMode"]
    assert_equal "design", tasks.second["layoutMode"]
    assert_equal "png", tasks.first.dig("output", "format")
    assert_equal 0.3, tasks.first.dig("layers", 1, "letterSpacingRatio")
    assert_equal true, tasks.first.dig("layers", 1, "bold")
    assert_equal "layer1", tasks.second.dig("layers", 1, "relativeTo")
    assert_nil tasks.second["warnings"]
    refute_equal "P1", ImageProjects::DefaultConfig.build(name: "Demo").dig("tasks", 0, "targetName")
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "real multi-row Chinese workbook creates only P1 and P2 with grouped layers" do
    project = ImageProject.create!(name: "Chinese Multi Row Import")
    path = Rails.root.join("tmp", "multi_row_chinese_import_test.xlsx")
    write_xlsx(path, multi_row_chinese_rows)

    config = ImageProjects::ExcelImporter.call(project, path)
    tasks = config["tasks"]
    p1 = tasks.first
    p2 = tasks.second

    assert_equal 2, tasks.size
    assert_equal [ "P1", "P2" ], tasks.map { |task| task["targetName"] }
    assert_equal "design", config["layoutMode"]
    assert_equal [ "design", "design" ], tasks.map { |task| task["layoutMode"] }
    refute_includes tasks.map { |task| task["targetName"] }, "Task 1"
    refute_includes tasks.map { |task| task["targetName"] }, "Task 2"

    assert_equal 1650, p1.dig("canvas", "width")
    assert_equal 2480, p1.dig("canvas", "height")
    assert_equal true, p1.dig("canvas", "transparent")
    assert_equal "transparent", p1.dig("canvas", "backgroundColor")
    assert_equal "png", p1.dig("output", "format")
    assert_equal 1, p1["layers"].count { |layer| layer["type"] == "image" }
    assert_equal 1, p1["layers"].count { |layer| layer["type"] == "text" }

    p1_image = p1["layers"].find { |layer| layer["type"] == "image" }
    p1_text = p1["layers"].find { |layer| layer["type"] == "text" }
    assert_equal "p1", p1_image["imageName"]
    assert_equal 1650, p1_image["width"]
    assert_equal 2480, p1_image["height"]
    assert_equal "center", p1_image["x"]
    assert_equal 0, p1_image["y"]
    assert_equal "cover", p1_image["fit"]
    assert_equal "留住温度 延长适饮", p1_text["text"]
    assert_equal "center", p1_text["x"]
    assert_equal 200, p1_text["y"]
    assert_equal "GenWanMinTW-Light.ttf", p1_text["font"]
    assert_in_delta 80, p1_text["fontSize"], 0.01
    assert_equal 0.3, p1_text["letterSpacingRatio"]
    refute p1_text.key?("letterSpacingMode")
    refute p1_text.key?("targetTextWidthRatio")
    assert_equal "#F4EAD7", p1_text["color"]
    assert_equal "center", p1_text["align"]
    assert_equal false, p1_text["autoWrap"]

    assert_equal "#FAFAF0", p2.dig("canvas", "backgroundColor")
    assert_equal "jpg", p2.dig("output", "format")
    assert_equal 1, p2["layers"].count { |layer| layer["type"] == "image" }
    assert_equal 3, p2["layers"].count { |layer| layer["type"] == "text" }

    p2_image = p2["layers"].find { |layer| layer["type"] == "image" }
    p2_text_layers = p2["layers"].select { |layer| layer["type"] == "text" }
    assert_equal "P2", p2_image["imageName"]
    assert_equal 600, p2_image["width"]
    assert_equal 600, p2_image["height"]
    assert_equal "center", p2_image["x"]
    assert_equal 500, p2_image["y"]
    assert_equal [ "设计亮点", "**DESIGN** HIGHLIGHTS", long_chinese_body ], p2_text_layers.map { |layer| layer["text"] }

    title, subtitle, body = p2_text_layers
    assert_equal 150, title["y"]
    assert_in_delta 80, title["fontSize"], 0.01
    assert_equal 0.3, title["letterSpacingRatio"]
    refute title.key?("letterSpacingMode")
    assert_equal "center", title["align"]
    assert_equal false, title["autoWrap"]
    assert_equal "layer1", subtitle["relativeTo"]
    assert_equal "below", subtitle["relativePosition"]
    refute subtitle.key?("relativeOffset")
    assert_in_delta 40, subtitle["fontSize"], 0.01
    assert_equal false, subtitle["bold"]
    assert_equal false, subtitle["autoWrap"]
    assert_equal "layer0", body["relativeTo"]
    assert_equal "below", body["relativePosition"]
    assert_equal 120, body["relativeOffset"]
    assert_in_delta 40, body["fontSize"], 0.01
    assert_equal 1188, body["maxWidth"]
    assert_equal 1.6, body["lineHeightRatio"]
    assert_equal true, body["autoWrap"]
    assert_equal "center", body["align"]
    refute p2.key?("warnings")
    assert_equal "P1", JSON.parse(project.reload.config_json).dig("tasks", 0, "targetName")
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "English Excel headers import correctly" do
    project = ImageProject.create!(name: "English Import")
    path = Rails.root.join("tmp", "english_import_test.xlsx")
    write_xlsx(path, [
      [ "target name", "canvas size", "background color", "source image", "image size", "image position", "output size", "text content", "text position", "font name", "font size", "notes" ],
      [ "EN1", "1650 x 2480 px", "white", "hero", "600 x 600 px", "500 px from canvas top", "1650 x 2480 px", "Premium Ceramic Cup", "top 200 px", "Brand Font", "60px", "increase letter spacing" ]
    ])

    task = ImageProjects::ExcelImporter.call(project, path).fetch("tasks").first

    assert_equal "EN1", task["targetName"]
    assert_equal "#FFFFFF", task.dig("canvas", "backgroundColor")
    assert_equal "hero", task.dig("layers", 0, "imageName")
    assert_equal 500, task.dig("layers", 0, "y")
    assert_equal "Premium Ceramic Cup", task.dig("layers", 1, "text")
    assert_equal 200, task.dig("layers", 1, "y")
    assert_equal 60, task.dig("layers", 1, "fontSize")
    assert_equal 0.3, task.dig("layers", 1, "letterSpacingRatio")
    assert_nil task.dig("layers", 1, "letterSpacingMode")
    assert_nil task.dig("layers", 1, "targetTextWidthRatio")
    assert_equal false, task.dig("layers", 1, "autoWrap")
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "explicit spread to width instruction imports spread mode" do
    project = ImageProject.create!(name: "Explicit Spread Import")
    path = Rails.root.join("tmp", "explicit_spread_import_test.xlsx")
    write_xlsx(path, [
      [ "target name", "canvas size", "background color", "text content", "text position", "font size", "notes" ],
      [ "SPREAD1", "1650 x 2480 px", "white", "Premium Ceramic Cup", "top 200 px", "60px", "spread text across 78% canvas width" ]
    ])

    task = ImageProjects::ExcelImporter.call(project, path).fetch("tasks").first
    text = task.dig("layers", 0)

    assert_equal "spread", text["letterSpacingMode"]
    assert_in_delta 0.78, text["targetTextWidthRatio"], 0.001
    assert_equal 0.3, text["letterSpacingRatio"]
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "source image instruction is not used as task name when target is missing" do
    project = ImageProject.create!(name: "Missing Target Import")
    path = Rails.root.join("tmp", "missing_target_import_test.xlsx")
    write_xlsx(path, [
      [ "target name", "source image", "text content" ],
      [ "", "使用图片名为p1", "Text" ]
    ])

    task = ImageProjects::ExcelImporter.call(project, path).fetch("tasks").first

    assert_equal "Task 1", task["targetName"]
    assert_equal "p1", task.dig("layers", 0, "imageName")
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "mixed Chinese and English headers import correctly" do
    project = ImageProject.create!(name: "Mixed Import")
    path = Rails.root.join("tmp", "mixed_import_test.xlsx")
    write_xlsx(path, [
      [ "输出图片名", "canvas size", "背景色", "source image", "image size", "图片位置", "text", "文字位置", "font", "字号", "instructions" ],
      [ "MIX1", "800 x 600 px", "black", "mix", "300 x 300 px", "距离顶部 80 px", "Designed for everyday drinking comfort", "200 px from top", "GenWanMinTW-Light", "32 pt", "letter spacing 30% bold auto wrap" ]
    ])

    task = ImageProjects::ExcelImporter.call(project, path).fetch("tasks").first

    assert_equal "MIX1", task["targetName"]
    assert_equal "#000000", task.dig("canvas", "backgroundColor")
    assert_equal 80, task.dig("layers", 0, "y")
    assert_equal 200, task.dig("layers", 1, "y")
    assert_in_delta 42.67, task.dig("layers", 1, "fontSize"), 0.01
    assert_equal 0.3, task.dig("layers", 1, "letterSpacingRatio")
    assert_equal true, task.dig("layers", 1, "bold")
    assert_equal true, task.dig("layers", 1, "autoWrap")
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  private

  def multi_row_chinese_rows
    [
      [
        "针对目标图片名", "步骤1", "", "步骤2", "", "", "", "", "步骤3", "", "", "", "", "步骤4", "", "", "", "", "步骤5", "", "", "", ""
      ],
      [
        "", "建立底层图层", "", "建立图层0", "", "", "", "", "建立图层1", "", "", "", "", "建立图层2", "", "", "", "", "建立图层3", "", "", "", ""
      ],
      [
        "", "图层尺寸", "调整图层颜色", "对应图片", "调整图片大小", "图片位置", "背景画布大小", "统一输出尺寸",
        "文字内容", "图层位置", "文字字体", "字体尺寸", "其他说明",
        "文字内容", "图层位置", "文字字体", "字体尺寸", "其他说明",
        "文字内容", "图层位置", "文字字体", "字体尺寸", "其他说明"
      ],
      [
        "P1", "1650 × 2480 px", "透明", "使用图片名为p1", "1650 × 2480 px", "", "", "1650 × 2480 px",
        "留住温度 延长适饮", "距离顶部200 px", "GenWanMinTW-Light.ttf", "60 pt", "将字体间距拉开",
        "", "", "", "", "", "", "", "", "", "", ""
      ],
      [
        "P2", "1650 × 2480 px", "#FAFAF0", "使用图片名为P2", "600*600px", "距离画布顶端500PX", "1650 × 2480 px", "1650 × 2480 px",
        "设计亮点", "距离顶部150PX", "AlibabaPuHuiTi-3-55-Regular", "60pt", "字距拉开至字号的30%",
        "DESIGN HIGHLIGHTS", "图层1下方居中", "AlibabaPuHuiTi-3-55-Regular", "30pt", "其中DESIGN这个单词加粗",
        long_chinese_body, "在图层0下面距离120PX", "AlibabaPuHuiTi-3-35-Thin", "30pt", ""
      ]
    ]
  end

  def long_chinese_body
    "双层陶瓷结构帮助热饮保持温度，圆润杯口贴合唇部，隐藏式杯盖减少热量散失，让每一次饮用都从容舒适，也让桌面陈列更显简洁精致。"
  end

  def write_xlsx(path, rows)
    FileUtils.mkdir_p(File.dirname(path))
    File.delete(path) if File.exist?(path)

    Zip::File.open(path, create: true) do |zip|
      zip.get_output_stream("[Content_Types].xml") { |io| io.write(content_types_xml) }
      zip.get_output_stream("_rels/.rels") { |io| io.write(root_rels_xml) }
      zip.get_output_stream("xl/workbook.xml") { |io| io.write(workbook_xml) }
      zip.get_output_stream("xl/_rels/workbook.xml.rels") { |io| io.write(workbook_rels_xml) }
      zip.get_output_stream("xl/worksheets/sheet1.xml") { |io| io.write(sheet_xml(rows)) }
    end
  end

  def content_types_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      </Types>
    XML
  end

  def root_rels_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      </Relationships>
    XML
  end

  def workbook_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
          <sheet name="Instructions" sheetId="1" r:id="rId1"/>
        </sheets>
      </workbook>
    XML
  end

  def workbook_rels_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      </Relationships>
    XML
  end

  def sheet_xml(rows)
    body = rows.each_with_index.map do |row, row_index|
      cells = row.each_with_index.map do |value, column_index|
        reference = "#{column_name(column_index)}#{row_index + 1}"
        escaped = ERB::Util.html_escape(value.to_s)
        %(<c r="#{reference}" t="inlineStr"><is><t>#{escaped}</t></is></c>)
      end.join
      %(<row r="#{row_index + 1}">#{cells}</row>)
    end.join

    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>#{body}</sheetData>
      </worksheet>
    XML
  end

  def column_name(index)
    name = +""
    current = index
    loop do
      name.prepend((65 + current % 26).chr)
      current = (current / 26) - 1
      break if current.negative?
    end
    name
  end
end
