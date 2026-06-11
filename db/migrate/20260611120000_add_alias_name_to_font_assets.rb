class AddAliasNameToFontAssets < ActiveRecord::Migration[8.1]
  class FontAssetRecord < ActiveRecord::Base
    self.table_name = "font_assets"
  end

  def up
    add_column :font_assets, :alias_name, :string, default: "" unless column_exists?(:font_assets, :alias_name)

    FontAssetRecord.reset_column_information
    FontAssetRecord.find_each do |asset|
      next if asset.alias_name.to_s.strip.present?

      alias_name = default_alias(asset.name.presence || asset.normalized_name)
      asset.update_columns(alias_name: alias_name.presence || asset.normalized_name.to_s.strip)
    end

    change_column_null :font_assets, :alias_name, false
    add_index :font_assets, [ :image_project_id, :alias_name ] unless index_exists?(:font_assets, [ :image_project_id, :alias_name ])
  end

  def down
    remove_index :font_assets, [ :image_project_id, :alias_name ] if index_exists?(:font_assets, [ :image_project_id, :alias_name ])
    remove_column :font_assets, :alias_name if column_exists?(:font_assets, :alias_name)
  end

  private

  def default_alias(value)
    text = value.to_s.strip
    base = File.basename(text, File.extname(text)).sub(/\s*\(\d+\)\z/, "")
    base.presence || text
  end
end
