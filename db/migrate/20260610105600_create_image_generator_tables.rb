class CreateImageGeneratorTables < ActiveRecord::Migration[8.1]
  def change
    create_table :image_projects do |t|
      t.string :name, null: false
      t.text :config_json, null: false, default: "{}"
      t.string :status, null: false, default: "draft"
      t.text :last_error

      t.timestamps
    end

    create_table :image_assets do |t|
      t.references :image_project, null: false, foreign_key: true
      t.string :name, null: false
      t.string :normalized_name, null: false
      t.integer :width
      t.integer :height

      t.timestamps
    end
    add_index :image_assets, [ :image_project_id, :normalized_name ]

    create_table :font_assets do |t|
      t.references :image_project, null: false, foreign_key: true
      t.string :name, null: false
      t.string :normalized_name, null: false

      t.timestamps
    end
    add_index :font_assets, [ :image_project_id, :normalized_name ]

    create_table :image_generation_jobs do |t|
      t.references :image_project, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.datetime :started_at
      t.datetime :finished_at
      t.text :warnings, null: false, default: "[]"
      t.text :errors, null: false, default: "[]"

      t.timestamps
    end

    create_table :generated_images do |t|
      t.references :image_generation_job, null: false, foreign_key: true
      t.string :target_name, null: false
      t.string :format, null: false
      t.integer :width
      t.integer :height
      t.text :warnings, null: false, default: "[]"
      t.text :errors, null: false, default: "[]"

      t.timestamps
    end
  end
end
