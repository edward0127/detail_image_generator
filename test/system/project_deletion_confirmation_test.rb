require "application_system_test_case"

class ProjectDeletionConfirmationTest < ApplicationSystemTestCase
  test "clicking delete from index opens confirmation and cancel keeps project" do
    project = ImageProject.create!(name: "Risky Project")

    visit image_projects_path

    within("tr", text: project.name) do
      click_link "Delete"
    end

    assert_current_path delete_confirmation_image_project_path(project, return_to: image_projects_path)
    assert_text "Delete Image Project"
    assert_text "This action cannot be undone."
    assert_selector "table.delete-summary-table"
    assert_text project.name
    assert ImageProject.exists?(project.id)

    within(".deletion-confirmation-form") do
      click_link "Cancel"
    end

    assert_current_path image_projects_path
    assert_text project.name
    assert ImageProject.exists?(project.id)
  end
end
