require "test_helper"
require "base64"
require "stringio"
require "zip"

class ImageProjects::ProjectDataResetterTest < ActiveSupport::TestCase
  PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

  test "resetter clears project content and keeps font libraries" do
    project = project_with_content
    project_name = project.name
    project_id = project.id
    global_font = global_font_asset("GlobalBrand.ttf")
    project_font = project_font_asset(project, "ProjectBrand.ttf")
    blobs_to_purge = content_blobs(project)
    kept_blobs = [ global_font.file.blob, project_font.file.blob ]

    assert blobs_to_purge.all? { |blob| blob.service.exist?(blob.key) }
    assert kept_blobs.all? { |blob| blob.service.exist?(blob.key) }

    ImageProjects::ProjectDataResetter.call(project)

    project.reload
    assert_equal project_id, project.id
    assert_equal project_name, project.name
    assert_equal "draft", project.status
    assert_nil project.last_error
    assert_equal [ "Task 1" ], project.tasks.map { |task| task["targetName"] }
    assert_equal 0, project.image_assets.count
    assert_equal 0, project.task_previews.count
    assert_equal 0, project.preview_generation_jobs.count
    assert_equal 0, project.image_generation_jobs.count
    refute project.preview_file.attached?
    assert_equal 1, project.font_assets.count
    assert_equal 1, GlobalFontAsset.count
    assert project_font.reload.file.attached?
    assert global_font.reload.file.attached?
    kept_blobs.each { |blob| assert blob.service.exist?(blob.key) }
    blobs_to_purge.each do |blob|
      refute ActiveStorage::Blob.exists?(blob.id)
      refute blob.service.exist?(blob.key)
    end
  end

  test "project can import Excel again after reset" do
    project = project_with_content
    path = Rails.root.join("tmp", "resetter_import_again.xlsx")

    ImageProjects::ProjectDataResetter.call(project)
    write_xlsx(path, [
      [ "target name", "text content", "notes" ],
      [ "AFTER_RESET", "DESIGN HIGHLIGHTS", "make DESIGN bold" ]
    ])

    config = ImageProjects::ExcelImporter.call(project, path)

    assert_equal "imported", project.reload.status
    assert_equal [ "AFTER_RESET" ], config["tasks"].map { |task| task["targetName"] }
    assert_equal "**DESIGN** HIGHLIGHTS", config.dig("tasks", 0, "layers", 0, "text")
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  private

  def project_with_content
    ImageProject.create!(name: "Reset Me").tap do |project|
      project.update!(
        status: "completed",
        last_error: "old error"
      )
      project.update_config!(
        "projectName" => "Reset Me",
        "tasks" => [
          {
            "targetName" => "P1",
            "canvas" => { "width" => 100, "height" => 100, "backgroundColor" => "#FFFFFF", "transparent" => false },
            "output" => { "width" => 100, "height" => 100, "format" => "png" },
            "layers" => [
              { "id" => "layer0", "name" => "Image", "type" => "image", "imageName" => "p1", "width" => 100, "height" => 100, "x" => "center", "y" => 0, "fit" => "contain", "opacity" => 1 }
            ]
          }
        ]
      )
      attach(project.preview_file, "legacy-preview.png", "image/png", png_bytes)
      image_asset_with_file(project, "p1.png")
      task_preview = project.task_previews.create!(task_index: 0, task_name: "P1", input_signature: "preview-signature", width: 1, height: 1, format: "png")
      attach(task_preview.file, "task-preview.png", "image/png", png_bytes)
      project.preview_generation_jobs.create!(
        status: "queued",
        scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE,
        task_indexes_json: JSON.generate([ 0 ]),
        input_signature: "preview-signature"
      )
      job = project.image_generation_jobs.create!(status: "completed", generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE, input_signature: "zip-signature")
      generated = job.generated_images.create!(target_name: "P1", format: "png", width: 1, height: 1)
      attach(generated.file, "P1.png", "image/png", png_bytes)
      attach(job.zip_file, "generated.zip", "application/zip", "zip")
    end
  end

  def content_blobs(project)
    blobs = []
    blobs << project.preview_file.blob if project.preview_file.attached?
    blobs.concat project.image_assets.filter_map { |asset| asset.file.blob if asset.file.attached? }
    blobs.concat project.task_previews.filter_map { |preview| preview.file.blob if preview.file.attached? }
    project.image_generation_jobs.each do |job|
      blobs << job.zip_file.blob if job.zip_file.attached?
      blobs.concat job.generated_images.filter_map { |generated| generated.file.blob if generated.file.attached? }
    end
    blobs
  end

  def image_asset_with_file(project, name)
    asset = project.image_assets.create!(
      name: name,
      alias_name: ImageProjects::AssetNameNormalizer.default_alias(name),
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name),
      width: 1,
      height: 1
    )
    attach(asset.file, name, "image/png", png_bytes)
    asset
  end

  def project_font_asset(project, name)
    asset = project.font_assets.create!(
      name: name,
      alias_name: ImageProjects::AssetNameNormalizer.default_alias(name),
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    attach(asset.file, name, "font/ttf", "project font")
    asset
  end

  def global_font_asset(name)
    asset = GlobalFontAsset.create!(
      name: name,
      match_name: ImageProjects::AssetNameNormalizer.default_alias(name),
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    attach(asset.file, name, "font/ttf", "global font")
    asset
  end

  def attach(attachment, filename, content_type, bytes)
    attachment.attach(io: StringIO.new(bytes), filename: filename, content_type: content_type)
    attachment.blob
  end

  def png_bytes
    Base64.decode64(PNG_1X1)
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
