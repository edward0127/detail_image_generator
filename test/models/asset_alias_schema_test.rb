require "test_helper"

class AssetAliasSchemaTest < ActiveSupport::TestCase
  test "image and font assets have alias_name columns" do
    assert ActiveRecord::Base.connection.column_exists?(:image_assets, :alias_name)
    assert ActiveRecord::Base.connection.column_exists?(:font_assets, :alias_name)
  end

  test "image assets default match name from uploaded filename" do
    project = ImageProject.create!(name: "Alias Schema")
    asset = project.image_assets.create!(
      name: "p1(1).png",
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless("p1(1).png")
    )

    assert_equal "p1", asset.alias_name
  end

  test "font assets default match name from uploaded filename" do
    project = ImageProject.create!(name: "Alias Schema")
    asset = project.font_assets.create!(
      name: "GenWanMinTW-Light.ttf",
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless("GenWanMinTW-Light.ttf")
    )

    assert_equal "GenWanMinTW-Light", asset.alias_name
  end
end
