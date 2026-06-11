require "application_system_test_case"
require "fileutils"
require "tmpdir"

class UploadButtonHighlightTest < ApplicationSystemTestCase
  setup do
    @upload_dir = Dir.mktmpdir("upload-button-highlight")
  end

  teardown do
    FileUtils.remove_entry(@upload_dir) if @upload_dir && Dir.exist?(@upload_dir)
  end

  test "workflow upload buttons highlight after file selection" do
    project = ImageProject.create!(name: "Uploads")

    visit image_project_path(project)

    attach_upload("excel", upload_file("tasks.xlsx"))
    assert_pending_upload("excel", "Import Excel Now")

    attach_upload("images", [
      upload_file("p1.png"),
      upload_file("p2.jpg")
    ])
    assert_pending_upload("images", "Upload 2 Images Now")

    attach_upload("fonts", [
      upload_file("brand.ttf"),
      upload_file("display.otf"),
      upload_file("fallback.ttc")
    ])
    assert_pending_upload("fonts", "Upload 3 Fonts Now")
  end

  test "upload reminder clears after successful upload reloads the page" do
    project = ImageProject.create!(name: "Uploads")

    visit image_project_path(project)

    attach_upload("fonts", upload_file("brand.ttf"))
    assert_pending_upload("fonts", "Upload 1 Font Now")

    within("form[data-upload-kind='fonts']") do
      click_button "Upload 1 Font Now"
    end

    assert_text "1 font(s) uploaded."
    assert_selector "form[data-upload-kind='fonts']"
    assert_no_selector "form[data-upload-kind='fonts'].upload-pending"

    within("form[data-upload-kind='fonts']") do
      assert_button "Upload Fonts"
      assert_no_text "File selected but not uploaded yet."
    end
  end

  private

  def upload_file(filename)
    path = File.join(@upload_dir, filename)
    File.binwrite(path, "test upload")
    path
  end

  def attach_upload(kind, paths)
    find("form[data-upload-kind='#{kind}'] input[type='file']", visible: :all).set(paths)
  end

  def assert_pending_upload(kind, button_text)
    form_selector = "form[data-upload-kind='#{kind}']"

    assert_selector "#{form_selector}.upload-pending"
    within(form_selector) do
      assert_button button_text
      assert_text "File selected but not uploaded yet."
    end
  end
end
