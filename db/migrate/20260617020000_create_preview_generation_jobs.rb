class CreatePreviewGenerationJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :preview_generation_jobs do |t|
      t.references :image_project, null: false, foreign_key: true
      t.string :status, null: false, default: "queued"
      t.string :scope, null: false
      t.text :task_indexes_json
      t.text :task_signatures_json
      t.string :input_signature
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :total_count, null: false, default: 0
      t.integer :previewable_count, null: false, default: 0
      t.integer :generated_count, null: false, default: 0
      t.integer :reused_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.text :warnings, null: false, default: "[]"
      t.text :error_messages, null: false, default: "[]"
      t.timestamps
    end

    add_index :preview_generation_jobs,
              [ :image_project_id, :scope, :input_signature, :status ],
              name: "idx_preview_jobs_project_scope_signature_status"
  end
end
