require "test_helper"
require "stringio"

class GlobalFontAssetTest < ActiveSupport::TestCase
  test "derives names from attached file" do
    asset = GlobalFontAsset.new
    asset.file.attach(io: StringIO.new("font data"), filename: "Brand Font.ttf", content_type: "font/ttf")

    assert asset.valid?
    assert_equal "Brand Font.ttf", asset.name
    assert_equal "brand font", asset.normalized_name
    assert_equal "Brand Font", asset.match_name
  end

  test "keeps submitted match name" do
    asset = GlobalFontAsset.new(name: "UploadedFont.woff2", match_name: "ExcelBrand")

    assert asset.valid?
    assert_equal "uploadedfont", asset.normalized_name
    assert_equal "ExcelBrand", asset.match_name
  end

  test "supports ttf otf woff and woff2 font files" do
    %w[Brand.ttf Brand.otf Brand.woff Brand.woff2].each do |filename|
      assert GlobalFontAsset.new(name: filename).valid?, "#{filename} should be supported"
    end
  end

  test "rejects unsupported extensions" do
    asset = GlobalFontAsset.new(name: "Brand.txt")

    refute asset.valid?
    assert_includes asset.errors[:name], "must be a supported font file (.ttf, .otf, .woff, or .woff2)"
  end
end
