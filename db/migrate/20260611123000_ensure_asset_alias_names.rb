class EnsureAssetAliasNames < ActiveRecord::Migration[8.1]
  class ImageAssetRecord < ActiveRecord::Base
    self.table_name = "image_assets"
  end

  class FontAssetRecord < ActiveRecord::Base
    self.table_name = "font_assets"
  end

  def up
    ensure_alias_column(:image_assets)
    ensure_alias_column(:font_assets)

    backfill_aliases(ImageAssetRecord)
    backfill_aliases(FontAssetRecord)

    change_column_default :image_assets, :alias_name, "" if column_exists?(:image_assets, :alias_name)
    change_column_default :font_assets, :alias_name, "" if column_exists?(:font_assets, :alias_name)
    change_column_null :image_assets, :alias_name, false if column_exists?(:image_assets, :alias_name)
    change_column_null :font_assets, :alias_name, false if column_exists?(:font_assets, :alias_name)

    add_index :image_assets, [ :image_project_id, :alias_name ] unless index_exists?(:image_assets, [ :image_project_id, :alias_name ])
    add_index :font_assets, [ :image_project_id, :alias_name ] unless index_exists?(:font_assets, [ :image_project_id, :alias_name ])
  end

  def down
    remove_index :image_assets, [ :image_project_id, :alias_name ] if index_exists?(:image_assets, [ :image_project_id, :alias_name ])
    remove_index :font_assets, [ :image_project_id, :alias_name ] if index_exists?(:font_assets, [ :image_project_id, :alias_name ])
  end

  private

  def ensure_alias_column(table)
    add_column table, :alias_name, :string, default: "" unless column_exists?(table, :alias_name)
  end

  def backfill_aliases(record_class)
    record_class.reset_column_information
    record_class.find_each do |asset|
      next if asset.alias_name.to_s.strip.present?

      alias_name = default_alias(asset.name.presence || asset.normalized_name)
      asset.update_columns(alias_name: alias_name.presence || asset.normalized_name.to_s.strip)
    end
  end

  def default_alias(value)
    text = value.to_s.strip
    base = File.basename(text, File.extname(text)).sub(/\s*\(\d+\)\z/, "")
    base.presence || text
  end
end
