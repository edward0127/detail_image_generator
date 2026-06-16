class CreateGlobalFontAssets < ActiveRecord::Migration[8.1]
  def change
    create_table :global_font_assets do |t|
      t.string :name, null: false
      t.string :match_name, null: false, default: ""
      t.string :normalized_name, null: false

      t.timestamps
    end

    add_index :global_font_assets, :normalized_name
    add_index :global_font_assets, :match_name
  end
end
