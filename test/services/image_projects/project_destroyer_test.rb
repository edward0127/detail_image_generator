require "test_helper"
require "base64"
require "stringio"

class ImageProjects::ProjectDestroyerTest < ActiveSupport::TestCase
  PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="

  test "destroyer removes project records and purges uploaded and generated files" do
    project = ImageProject.create!(name: "Destroy Me")
    preview_blob = attach(project.preview_file, "preview.png", "image/png", Base64.decode64(PNG_1X1))
    image_asset = image_asset_with_file(project, "p1.png")
    font_asset = font_asset_with_file(project, "Brand.ttf")
    job = project.image_generation_jobs.create!(status: "completed")
    generated = job.generated_images.create!(target_name: "P1", format: "png", width: 1, height: 1)
    generated_blob = attach(generated.file, "P1.png", "image/png", Base64.decode64(PNG_1X1))
    zip_blob = attach(job.zip_file, "generated.zip", "application/zip", "zip-bytes")
    blobs = [ preview_blob, image_asset.file.blob, font_asset.file.blob, generated_blob, zip_blob ]

    assert blobs.all? { |blob| blob.service.exist?(blob.key) }

    ImageProjects::ProjectDestroyer.call(project)

    refute ImageProject.exists?(project.id)
    refute ImageAsset.exists?(image_asset.id)
    refute FontAsset.exists?(font_asset.id)
    refute ImageGenerationJob.exists?(job.id)
    refute GeneratedImage.exists?(generated.id)
    blobs.each do |blob|
      refute ActiveStorage::Blob.exists?(blob.id)
      refute blob.service.exist?(blob.key)
    end
  end

  test "destroying one project does not affect another project files" do
    doomed = ImageProject.create!(name: "Destroy Me")
    survivor = ImageProject.create!(name: "Keep Me")
    image_asset_with_file(doomed, "p1.png")
    survivor_asset = image_asset_with_file(survivor, "p2.png")
    survivor_blob = survivor_asset.file.blob

    ImageProjects::ProjectDestroyer.call(doomed)

    assert ImageProject.exists?(survivor.id)
    assert ImageAsset.exists?(survivor_asset.id)
    assert survivor_blob.service.exist?(survivor_blob.key)
    assert survivor_asset.reload.file.attached?
  ensure
    survivor&.destroy
  end

  private

  def image_asset_with_file(project, name)
    asset = project.image_assets.create!(
      name: name,
      alias_name: ImageProjects::AssetNameNormalizer.default_alias(name),
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name),
      width: 1,
      height: 1
    )
    attach(asset.file, name, "image/png", Base64.decode64(PNG_1X1))
    asset
  end

  def font_asset_with_file(project, name)
    asset = project.font_assets.create!(
      name: name,
      alias_name: ImageProjects::AssetNameNormalizer.default_alias(name),
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    attach(asset.file, name, "font/ttf", "font-bytes")
    asset
  end

  def attach(attachment, filename, content_type, bytes)
    attachment.attach(
      io: StringIO.new(bytes),
      filename: filename,
      content_type: content_type
    )
    attachment.blob
  end
end
