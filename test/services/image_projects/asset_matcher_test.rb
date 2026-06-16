require "test_helper"
require "stringio"

class ImageProjects::AssetMatcherTest < ActiveSupport::TestCase
  test "font matcher supports full file name matching" do
    project = ImageProject.create!(name: "Matcher")
    font = create_font_asset(project, "Brand Font.ttf")

    result = ImageProjects::FontMatcher.new(project).match("Brand Font.ttf")

    assert_equal font, result.asset
    assert_nil result.warning
  end

  test "font matcher supports extensionless matching" do
    project = ImageProject.create!(name: "Matcher")
    font = create_font_asset(project, "Brand Font.ttf")

    result = ImageProjects::FontMatcher.new(project).match("Brand Font")

    assert_equal font, result.asset
    assert_nil result.warning
  end

  test "font matcher is case-insensitive" do
    project = ImageProject.create!(name: "Matcher")
    font = create_font_asset(project, "Brand Font.ttf")

    result = ImageProjects::FontMatcher.new(project).match("brand font.TTF")

    assert_equal font, result.asset
  end

  test "font matcher supports loose matching that ignores spaces underscores and hyphens" do
    project = ImageProject.create!(name: "Matcher")
    font = create_font_asset(project, "Gen Wan-Min_TW.ttf")

    result = ImageProjects::FontMatcher.new(project).match("GenWanMinTW")

    assert_equal font, result.asset
    assert result.warning.include?("matched loosely")
  end

  test "font matcher supports editable aliases" do
    project = ImageProject.create!(name: "Matcher")
    font = create_font_asset(project, "Uploaded Chinese Font.ttf", alias_name: "GenWanMinTW-Light")

    result = ImageProjects::FontMatcher.new(project).match("GenWanMinTW-Light")

    assert_equal font, result.asset
  end

  test "font matcher records warning when missing and falls back" do
    project = ImageProject.create!(name: "Matcher")

    result = ImageProjects::FontMatcher.new(project).match("Missing.ttf")

    assert result.fallback?
    assert result.warning.include?("was not uploaded")
    assert result.warning.include?("may not visually match the expected design")
  end

  test "image matcher supports case-insensitive image names and common extensions" do
    project = ImageProject.create!(name: "Matcher")
    image = create_image_asset(project, "Product_Main.PNG")

    assert_equal image, ImageProjects::ImageMatcher.new(project).match("product_main.png").asset
    assert_equal image, ImageProjects::ImageMatcher.new(project).match("PRODUCT_MAIN").asset
    assert_equal image, ImageProjects::ImageMatcher.new(project).match("product_main.jpg").asset
  end

  test "image matcher matches imported p1 and P2 references to uploaded files" do
    project = ImageProject.create!(name: "Matcher")
    p1 = create_image_asset(project, "p1.png")
    p2 = create_image_asset(project, "p2.png")

    assert_equal p1, ImageProjects::ImageMatcher.new(project).match("p1").asset
    assert_equal p2, ImageProjects::ImageMatcher.new(project).match("P2").asset
  end

  test "image matcher ignores common duplicate filename suffixes loosely" do
    project = ImageProject.create!(name: "Matcher")
    image = create_image_asset(project, "p1(1).png", alias_name: "uploaded-copy")

    result = ImageProjects::ImageMatcher.new(project).match("p1")

    assert_equal image, result.asset
    assert result.warning.include?("matched loosely")
  end

  test "image matcher supports editable aliases" do
    project = ImageProject.create!(name: "Matcher")
    image = create_image_asset(project, "Weixin Image_20260610131925_68_72.png", alias_name: "p1")

    assert_equal image, ImageProjects::ImageMatcher.new(project).match("p1").asset
  end

  test "image matcher supports loose uploaded name and alias matching" do
    project = ImageProject.create!(name: "Matcher")
    image = create_image_asset(project, "Product Main-Image.PNG", alias_name: "Hero_Image")

    assert_equal image, ImageProjects::ImageMatcher.new(project).match("productmainimage").asset
    assert_equal image, ImageProjects::ImageMatcher.new(project).match("hero image.png").asset
  end

  test "image matcher returns clear error for missing images" do
    project = ImageProject.create!(name: "Matcher")

    result = ImageProjects::ImageMatcher.new(project).match("missing")

    refute result.found?
    assert result.error.include?("was not found")
  end

  private

  def create_font_asset(project, name, alias_name: nil)
    asset = project.font_assets.create!(
      name: name,
      alias_name: alias_name,
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    asset.file.attach(io: StringIO.new("font data"), filename: name, content_type: "font/#{File.extname(name).delete(".")}")
    asset
  end

  def create_image_asset(project, name, alias_name: nil)
    project.image_assets.create!(
      name: name,
      alias_name: alias_name,
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
  end
end
