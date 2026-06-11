class RenameGenerationErrorColumns < ActiveRecord::Migration[8.1]
  def change
    rename_column :image_generation_jobs, :errors, :error_messages
    rename_column :generated_images, :errors, :error_messages
  end
end
