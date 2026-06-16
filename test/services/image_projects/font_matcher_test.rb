require "test_helper"
require "stringio"

class ImageProjects::FontMatcherTest < ActiveSupport::TestCase
  test "matches global font by uploaded filename" do
    project = ImageProject.create!(name: "Matcher")
    font = create_global_font_asset("GenWanMinTW-Light.ttf")

    result = ImageProjects::FontMatcher.new(project).match("GenWanMinTW-Light.ttf")

    assert_equal font, result.asset
    assert_nil result.warning
    refute result.fallback?
  end

  test "matches global font by extensionless name" do
    project = ImageProject.create!(name: "Matcher")
    font = create_global_font_asset("GenWanMinTW-Light.ttf")

    result = ImageProjects::FontMatcher.new(project).match("GenWanMinTW-Light")

    assert_equal font, result.asset
    assert_nil result.warning
    refute result.fallback?
  end

  test "matches global font by Excel match name" do
    project = ImageProject.create!(name: "Matcher")
    font = create_global_font_asset("CustomUpload.ttf", match_name: "ExcelBrandFont")

    result = ImageProjects::FontMatcher.new(project).match("ExcelBrandFont")

    assert_equal font, result.asset
    assert_nil result.warning
    refute result.fallback?
  end

  test "matches global font by case insensitive exact filename without warning" do
    project = ImageProject.create!(name: "Matcher")
    font = create_global_font_asset("BrandFont.TTF")

    result = ImageProjects::FontMatcher.new(project).match("brandfont.ttf")

    assert_equal font, result.asset
    assert_nil result.warning
    refute result.fallback?
  end

  test "matches global font with loose normalized name" do
    project = ImageProject.create!(name: "Matcher")
    font = create_global_font_asset("Alibaba PuHuiTi-3_55 Regular.woff2")

    result = ImageProjects::FontMatcher.new(project).match("AlibabaPuHuiTi355Regular")

    assert_equal font, result.asset
    assert result.warning.include?("matched loosely")
  end

  test "prefers project-specific legacy font over global font" do
    project = ImageProject.create!(name: "Matcher")
    project_font = create_project_font_asset(project, "Brand.ttf")
    create_global_font_asset("Brand.ttf")

    result = ImageProjects::FontMatcher.new(project).match("Brand.ttf")

    assert_equal project_font, result.asset
  end

  test "matches project-specific legacy alias before global fallback" do
    project = ImageProject.create!(name: "Matcher")
    project_font = create_project_font_asset(project, "LegacyUpload.ttf", alias_name: "BrandAlias")
    create_global_font_asset("BrandAlias.ttf")

    result = ImageProjects::FontMatcher.new(project).match("BrandAlias")

    assert_equal project_font, result.asset
  end

  test "warns only when font is missing from project and global assets" do
    project = ImageProject.create!(name: "Matcher")
    create_global_font_asset("ExistingGlobal.ttf")

    found = ImageProjects::FontMatcher.new(project).match("ExistingGlobal.ttf")
    missing = ImageProjects::FontMatcher.new(project).match("Missing.ttf")

    refute found.fallback?
    assert_nil found.warning
    assert missing.fallback?
    assert missing.warning.include?("Font \"Missing.ttf\" was not uploaded.")
  end

  test "warns when multiple global fonts can match" do
    project = ImageProject.create!(name: "Matcher")
    first = create_global_font_asset("Brand.ttf")
    create_global_font_asset("brand.otf")

    result = ImageProjects::FontMatcher.new(project).match("Brand")

    assert_equal first, result.asset
    assert result.warning.include?("Multiple fonts matched")
    refute result.fallback?
  end

  test "matching global font records without attached files warn and fall back" do
    project = ImageProject.create!(name: "Matcher")
    asset = GlobalFontAsset.create!(
      name: "FilelessBrand.ttf",
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless("FilelessBrand.ttf")
    )

    result = ImageProjects::FontMatcher.new(project).match("FilelessBrand.ttf")

    assert_equal asset, result.asset
    assert result.fallback?
    assert result.warning.include?("has no attached file")
  end

  test "matching project font records without attached files warn and fall back" do
    project = ImageProject.create!(name: "Matcher")
    asset = project.font_assets.create!(
      name: "FilelessProject.ttf",
      alias_name: "FilelessProject",
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless("FilelessProject.ttf")
    )

    result = ImageProjects::FontMatcher.new(project).match("FilelessProject.ttf")

    assert_equal asset, result.asset
    assert result.fallback?
    assert result.warning.include?("has no attached file")
  end

  private

  def create_global_font_asset(name, match_name: nil)
    asset = GlobalFontAsset.create!(
      name: name,
      match_name: match_name,
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    asset.file.attach(io: StringIO.new("font data"), filename: name, content_type: font_content_type(name))
    asset
  end

  def create_project_font_asset(project, name, alias_name: nil)
    asset = project.font_assets.create!(
      name: name,
      alias_name: alias_name,
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    asset.file.attach(io: StringIO.new("font data"), filename: name, content_type: font_content_type(name))
    asset
  end

  def font_content_type(name)
    "font/#{File.extname(name).delete(".")}"
  end
end
