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

    open_font_library_panel
    find("#font-library-manager summary").click
    attach_upload("global-fonts", [
      upload_file("brand.ttf"),
      upload_file("display.otf"),
      upload_file("fallback.woff2")
    ])
    assert_pending_upload("global-fonts", "Upload 3 Fonts Now")
  end

  test "upload reminder clears after successful upload reloads the page" do
    project = ImageProject.create!(name: "Uploads")

    visit image_project_path(project)

    open_font_library_panel
    find("#font-library-manager summary").click
    attach_upload("global-fonts", upload_file("brand.ttf"))
    assert_pending_upload("global-fonts", "Upload 1 Font Now")

    within("form[data-upload-kind='global-fonts']") do
      click_button "Upload 1 Font Now"
    end

    assert_text "1 font(s) uploaded."
    assert_selector "form[data-upload-kind='global-fonts']"
    assert_no_selector "form[data-upload-kind='global-fonts'].upload-pending"

    within("form[data-upload-kind='global-fonts']") do
      assert_button "Upload Font"
      assert_no_text "File selected but not uploaded yet."
    end
  end

  test "success notice auto dismisses and alert remains" do
    project = text_layer_project(font: "")

    visit image_project_path(project)
    click_button "Save & Preview"

    assert_text "Configuration saved. Preview generation started.", wait: 10
    assert_selector ".flash.notice button[aria-label='Dismiss message']"
    sleep 6
    assert_no_text "Configuration saved."

    click_button "Import Excel"

    assert_text "Excel import failed: Choose an Excel file to import.", wait: 10
    sleep 6
    assert_text "Excel import failed: Choose an Excel file to import."
  end

  test "success notice can be dismissed manually" do
    project = text_layer_project(font: "")

    visit image_project_path(project)
    click_button "Save & Preview"

    assert_text "Configuration saved. Preview generation started.", wait: 10
    find(".flash.notice button[aria-label='Dismiss message']").click
    assert_no_selector ".flash.notice", wait: 2
  end

  test "text layer upload control opens highlights and focuses global font upload form" do
    project = text_layer_project(font: "")

    visit image_project_path(project)
    find("details.layers-panel summary").click
    click_link "Upload new font"

    assert_selector "details#font-library[open]"
    assert_selector "details#font-library-manager[open]"
    assert_selector "#global-font-upload-form.font-library-highlight"
    assert_equal "global-font-file-input", page.evaluate_script("document.activeElement.id")
    assert_text "Choose font files below."
  end

  test "font library hash opens manager on page load" do
    project = ImageProject.create!(name: "Uploads")

    visit "#{image_project_path(project)}#font-library"

    assert_selector "details#font-library[open]"
    assert_selector "details#font-library-manager[open]"
  end

  test "download zip button starts json job flow and resets after enqueue" do
    project = text_layer_project(font: "")

    visit image_project_path(project)

    page.execute_script("window.__detailImageGeneratorAjaxMarker = 'zip';")
    click_button "Generate ZIP (All Images)"

    assert_equal "zip", page.evaluate_script("window.__detailImageGeneratorAjaxMarker")
    assert_selector "[data-zip-status-panel].status-queued", wait: 10
    assert_text "ZIP generation started", wait: 10
    assert_button "Generate ZIP (All Images)", disabled: true, wait: 10
    assert_no_selector "button.is-processing"
    assert_equal 1, project.image_generation_jobs.count
  end

  test "download zip html error response is shown to the user" do
    project = text_layer_project(font: "")

    visit image_project_path(project)
    page.execute_script(<<~JS)
      window.fetch = function() {
        return Promise.resolve(new Response(
          "<!doctype html><html><body><div class='flash alert'>ZIP failed in test</div></body></html>",
          { status: 422, headers: { "Content-Type": "text/html" } }
        ));
      };
    JS

    click_button "Generate ZIP (All Images)"

    assert_text "ZIP failed in test"
  end

  test "preview all button starts background preview flow and resets after enqueue" do
    project = text_layer_project(font: "", names: [ "P1", "P2" ])

    with_forgery_protection do
      visit image_project_path(project)

      assert_button "Preview All Images", disabled: false
      assert_selector "button[data-processing-label='Generating all previews...']", text: "Preview All Images"
      assert_nil page.evaluate_script("document.querySelector(\"button[name='after_save_action'][value='preview_all']\").getAttribute('formaction')")
      assert_equal image_project_path(project), page.evaluate_script("new URL(document.getElementById('task-editor-form').action).pathname")

      page.execute_script("window.__detailImageGeneratorAjaxMarker = 'preview-all';")
      click_button "Preview All Images"

      assert_equal "preview-all", page.evaluate_script("window.__detailImageGeneratorAjaxMarker")
      assert_no_text "Can't verify CSRF token authenticity"
      assert_text "Preview generation started for 2 tasks.", wait: 10
      assert_selector "[data-preview-status-panel].status-queued", wait: 10
      assert_button "Preview All Images", disabled: true, wait: 10
      assert_no_selector "button.is-processing"
    end

    preview_job = project.preview_generation_jobs.last
    assert_equal PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE, preview_job.scope
    assert_equal [ 0, 1 ], preview_job.task_indexes
  end

  test "project name save and preview button uses selected preview background flow" do
    project = text_layer_project(font: "")

    visit image_project_path(project)

    assert_selector ".form-toolbar button[name='after_save_action'][value='preview_current']", text: "Save & Preview"
    assert_nil page.evaluate_script("document.querySelector(\".form-toolbar button[name='after_save_action'][value='preview_current']\").getAttribute('formaction')")
    toolbar_control_top_delta = page.evaluate_script(<<~JS)
        Math.abs(
          document.querySelector(".form-toolbar input[name='image_project[name]']").getBoundingClientRect().top -
          document.querySelector(".form-toolbar button[name='after_save_action'][value='preview_current']").getBoundingClientRect().top
        )
    JS
    assert_operator toolbar_control_top_delta, :<, 6

    fill_in "Project Name", with: "Renamed Uploads"
    page.execute_script("window.__detailImageGeneratorAjaxMarker = 'project-name-preview';")
    click_button "Save & Preview"

    assert_equal "project-name-preview", page.evaluate_script("window.__detailImageGeneratorAjaxMarker")
    assert_text "Configuration saved. Preview generation started.", wait: 10
    assert_selector "[data-preview-status-panel].status-queued", wait: 10
    assert_no_selector "button.is-processing"

    assert_equal "Renamed Uploads", project.reload.name
    assert_equal [ 0 ], project.preview_generation_jobs.last.task_indexes
  end

  test "save and generate preview button saves and starts background selected preview" do
    project = text_layer_project(font: "")

    visit image_project_path(project)
    find("details.layers-panel summary").click

    fill_in "layers[0][text]", with: "Updated preview title"
    assert_selector ".generate-step button[name='after_save_action'][value='preview_current'][data-processing-label='Generating preview...']", text: "Preview Selected Image"
    assert_nil page.evaluate_script("document.querySelector(\".generate-step button[name='after_save_action'][value='preview_current']\").getAttribute('formaction')")

    page.execute_script("window.__detailImageGeneratorAjaxMarker = 'selected-preview';")
    click_button "Preview Selected Image"

    assert_equal "selected-preview", page.evaluate_script("window.__detailImageGeneratorAjaxMarker")
    assert_text "Configuration saved. Preview generation started.", wait: 10
    assert_selector "[data-preview-status-panel].status-queued", wait: 10
    assert_button "Preview Selected Image", disabled: true, wait: 10
    assert_no_selector "button.is-processing"

    assert_equal "Updated preview title", project.reload.config_hash.dig("tasks", 0, "layers", 0, "text")
    assert_equal [ 0 ], project.preview_generation_jobs.last.task_indexes
  end

  private

  def text_layer_project(font:, names: [ "P1" ])
    ImageProject.create!(name: "Uploads").tap do |project|
      project.update_config!(
        "projectName" => "Uploads",
        "tasks" => names.map do |name|
          {
            "targetName" => name,
            "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
            "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
            "layers" => [
              {
                "id" => "layer0",
                "name" => "Title",
                "type" => "text",
                "text" => "#{name} Title",
                "font" => font,
                "fontSize" => 80,
                "color" => "#111111",
                "letterSpacingRatio" => 0,
                "lineHeightRatio" => 1.2,
                "maxWidth" => 1200,
                "autoWrap" => false,
                "bold" => false,
                "italic" => false,
                "x" => "center",
                "y" => 200,
                "align" => "center",
                "opacity" => 1
              }
            ]
          }
        end
      )
    end
  end

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

  def open_font_library_panel
    assert_selector "details#font-library"
    find("details#font-library > summary").click unless page.has_selector?("details#font-library[open]", wait: 0)
  end

  def with_singleton_method_stub(object, method_name, replacement)
    original_method = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name) do |*args, **kwargs, &block|
      original_method.call(*args, **kwargs, &block)
    end
  end

  def with_forgery_protection
    original_allow_forgery_protection = ActionController::Base.allow_forgery_protection
    original_per_form_csrf_tokens = ActionController::Base.per_form_csrf_tokens
    ActionController::Base.allow_forgery_protection = true
    ActionController::Base.per_form_csrf_tokens = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original_allow_forgery_protection
    ActionController::Base.per_form_csrf_tokens = original_per_form_csrf_tokens
  end
end
