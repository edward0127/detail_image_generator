class TaskPreview < ApplicationRecord
  belongs_to :image_project
  has_one_attached :file

  validates :task_index, presence: true
  validates :task_name, presence: true
  validates :input_signature, presence: true
end
