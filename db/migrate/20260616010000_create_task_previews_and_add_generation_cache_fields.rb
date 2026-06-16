class CreateTaskPreviewsAndAddGenerationCacheFields < ActiveRecord::Migration[8.1]
  def change
    create_table :task_previews do |t|
      t.references :image_project, null: false, foreign_key: true
      t.integer :task_index, null: false
      t.string :task_name, null: false
      t.string :input_signature, null: false
      t.integer :width
      t.integer :height
      t.string :format

      t.timestamps
    end

    add_index :task_previews, [ :image_project_id, :task_index ]
    add_index :task_previews, :input_signature
    add_index :task_previews,
              [ :image_project_id, :task_index, :input_signature ],
              unique: true,
              name: "idx_task_previews_project_task_signature"

    add_column :image_generation_jobs, :input_signature, :string
    add_column :image_generation_jobs, :generation_scope, :string
    add_column :image_generation_jobs, :task_indexes_json, :text
    add_index :image_generation_jobs,
              [ :image_project_id, :generation_scope, :input_signature ],
              name: "idx_generation_jobs_project_scope_signature"
    add_index :image_generation_jobs,
              [ :image_project_id, :generation_scope, :created_at ],
              name: "idx_generation_jobs_project_scope_created"
  end
end
