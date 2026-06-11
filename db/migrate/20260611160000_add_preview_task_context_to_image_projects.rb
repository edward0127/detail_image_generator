class AddPreviewTaskContextToImageProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :image_projects, :preview_task_index, :integer
    add_column :image_projects, :preview_task_name, :string
  end
end
