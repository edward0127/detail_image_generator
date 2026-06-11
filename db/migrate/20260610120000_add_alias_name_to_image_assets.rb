class AddAliasNameToImageAssets < ActiveRecord::Migration[8.1]
  class ImageAssetRecord < ActiveRecord::Base
    self.table_name = "image_assets"
  end

  def up
    add_column :image_assets, :alias_name, :string, default: "" unless column_exists?(:image_assets, :alias_name)

    ImageAssetRecord.reset_column_information
    ImageAssetRecord.find_each do |asset|
      next if asset.alias_name.to_s.strip.present?

      alias_name = default_alias(asset.name.presence || asset.normalized_name)
      asset.update_columns(alias_name: alias_name.presence || asset.normalized_name.to_s.strip)
    end

    change_column_null :image_assets, :alias_name, false
    add_index :image_assets, [ :image_project_id, :alias_name ] unless index_exists?(:image_assets, [ :image_project_id, :alias_name ])
  end

  def down
    remove_index :image_assets, [ :image_project_id, :alias_name ] if index_exists?(:image_assets, [ :image_project_id, :alias_name ])
    remove_column :image_assets, :alias_name if column_exists?(:image_assets, :alias_name)
  end

  private

  def default_alias(value)
    text = value.to_s.strip
    base = File.basename(text, File.extname(text)).sub(/\s*\(\d+\)\z/, "")
    base.presence || text
  end
end
