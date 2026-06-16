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

  test "text layer upload control opens highlights and focuses global font upload form" do
    project = text_layer_project(font: "")

    visit image_project_path(project)
    find("details.layers-panel summary").click
    click_link "Upload new font"

    assert_selector "details#font-library-manager[open]"
    assert_selector "#global-font-upload-form.font-library-highlight"
    assert_equal "global-font-file-input", page.evaluate_script("document.activeElement.id")
    assert_text "Choose font files below."
  end

  test "font library hash opens manager on page load" do
    project = ImageProject.create!(name: "Uploads")

    visit "#{image_project_path(project)}#font-library"

    assert_selector "details#font-library-manager[open]"
  end

  test "download zip button resets after successful blob download" do
    project = text_layer_project(font: "")

    visit image_project_path(project)
    install_successful_download_fetch_stub

    click_button "Download ZIP (All Images)"

    assert_button "Download ZIP (All Images)", disabled: false
    assert_equal "download_zip", page.evaluate_script("window.__downloadZipFetchCalls[0].action")
    assert_equal "test.zip", page.evaluate_script("window.__downloadZipAnchor.download")
    assert_equal "application/zip", page.evaluate_script("window.__downloadZipDownloads[0].type")
    assert_no_selector "button.is-processing"
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

    click_button "Download ZIP (All Images)"

    assert_text "ZIP failed in test"
  end

  private

  def text_layer_project(font:)
    ImageProject.create!(name: "Uploads").tap do |project|
      project.update_config!(
        "projectName" => "Uploads",
        "tasks" => [
          {
            "targetName" => "P1",
            "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
            "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
            "layers" => [
              {
                "id" => "layer0",
                "name" => "Title",
                "type" => "text",
                "text" => "Title",
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
        ]
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

  def install_successful_download_fetch_stub
    page.execute_script(<<~JS)
      window.__downloadZipFetchCalls = [];
      window.__downloadZipDownloads = [];
      window.fetch = function(url, options) {
        window.__downloadZipFetchCalls.push({
          url: url,
          method: options.method,
          action: options.body.get("after_save_action"),
          csrf: options.headers["X-CSRF-Token"]
        });
        return Promise.resolve(new Response(
          new Blob(["zip-bytes"], { type: "application/zip" }),
          {
            status: 200,
            headers: {
              "Content-Type": "application/zip",
              "Content-Disposition": "attachment; filename=\\"test.zip\\""
            }
          }
        ));
      };
      window.URL.createObjectURL = function(blob) {
        window.__downloadZipDownloads.push({ type: blob.type, size: blob.size });
        return "blob:test-download";
      };
      window.URL.revokeObjectURL = function(url) {
        window.__downloadZipRevokedUrl = url;
      };
      HTMLAnchorElement.prototype.click = function() {
        window.__downloadZipAnchor = { href: this.href, download: this.download };
      };
    JS
  end
end
