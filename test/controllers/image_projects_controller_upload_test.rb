require "test_helper"
require "stringio"

class ImageProjectsControllerUploadTest < ActionDispatch::IntegrationTest
  class ExplodingOriginalFilename
    def original_filename
      raise "original_filename should not be called"
    end
  end

  setup do
    @tempfiles = []
  end

  teardown do
    @tempfiles.each do |tempfile|
      tempfile.close
      tempfile.unlink
    end
  end

  test "upload images ignores blank hidden value and uploads one file" do
    project = create_project
    upload = uploaded_file("p1.png", "image/png")

    assert_difference -> { project.image_assets.count }, 1 do
      post upload_images_image_project_path(project), params: { images: [ "", upload ] }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "1 image(s) uploaded."

    asset = project.image_assets.last
    assert_equal "p1.png", asset.name
    assert_equal "p1", asset.alias_name
  end

  test "upload images accepts multiple uploaded files" do
    project = create_project
    uploads = [
      uploaded_file("p1.png", "image/png"),
      uploaded_file("p2.jpg", "image/jpeg")
    ]

    assert_difference -> { project.image_assets.count }, 2 do
      post upload_images_image_project_path(project), params: { images: uploads }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal [ "p1.png", "p2.jpg" ], project.image_assets.order(:name).pluck(:name)
  end

  test "upload images defaults duplicate filename match name to clean base" do
    project = create_project
    upload = uploaded_file("p1(1).png", "image/png")

    assert_difference -> { project.image_assets.count }, 1 do
      post upload_images_image_project_path(project), params: { images: [ upload ] }
    end

    assert_equal "p1", project.image_assets.last.alias_name
  end

  test "upload images skips unsupported extensions safely" do
    project = create_project
    upload = uploaded_file("product.gif", "image/gif")

    assert_no_difference -> { project.image_assets.count } do
      post upload_images_image_project_path(project), params: { images: [ upload ] }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "0 image(s) uploaded."
    assert_includes response.body, "Skipped unsupported files: product.gif"
  end

  test "upload fonts ignores blank hidden value and uploads one file" do
    project = create_project
    upload = uploaded_file("brand.ttf", "font/ttf")

    assert_difference -> { project.font_assets.count }, 1 do
      post upload_fonts_image_project_path(project), params: { fonts: [ "", upload ] }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "1 font(s) uploaded."
    assert_equal "brand.ttf", project.font_assets.last.name
    assert_equal "brand", project.font_assets.last.alias_name
  end

  test "upload fonts accepts multiple uploaded files" do
    project = create_project
    uploads = [
      uploaded_file("brand.ttf", "font/ttf"),
      uploaded_file("display.otf", "font/otf")
    ]

    assert_difference -> { project.font_assets.count }, 2 do
      post upload_fonts_image_project_path(project), params: { fonts: uploads }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal [ "brand.ttf", "display.otf" ], project.font_assets.order(:name).pluck(:name)
  end

  test "upload global fonts creates font library assets" do
    project = create_project
    upload = uploaded_file("brand.woff2", "font/woff2")

    assert_difference -> { GlobalFontAsset.count }, 1 do
      assert_no_difference -> { project.font_assets.count } do
        post upload_global_fonts_image_project_path(project), params: {
          fonts: [ upload ],
          global_font_asset: { match_name: "ExcelBrand" }
        }
      end
    end

    assert_redirected_to image_project_path(project, task_index: 0, anchor: "font-library")
    follow_redirect!
    assert_includes response.body, "1 font(s) uploaded."
    assert_includes response.body, "Uploaded fonts are available in the global Font Library."

    asset = GlobalFontAsset.last
    assert_equal "brand.woff2", asset.name
    assert_equal "ExcelBrand", asset.match_name
    assert asset.file.attached?
  end

  test "uploaded global font becomes available in text layer dropdown" do
    project = create_project
    task = task_config("P1")
    task["layers"] = [ text_layer_config.merge("font" => "") ]
    project.update_config!(
      "projectName" => "Uploads",
      "tasks" => [ task ]
    )

    post upload_global_fonts_image_project_path(project), params: {
      fonts: [ uploaded_file("GlobalBrand.ttf", "font/ttf") ]
    }

    follow_redirect!
    assert_select "select[name='layers[0][font]'] option[value='GlobalBrand.ttf']", text: "GlobalBrand.ttf (Global)"
  end

  test "text layer font dropdown lists global project and missing current fonts" do
    project = create_project
    create_global_font_asset("GlobalBrand.ttf")
    create_project_font_asset(project, "LegacyProject.ttf", alias_name: "LegacyProject")
    task = task_config("P1")
    task["layers"] = [ text_layer_config.merge("font" => "MissingCurrent.ttf") ]
    project.update_config!(
      "projectName" => "Uploads",
      "tasks" => [ task ]
    )

    get image_project_path(project)

    assert_response :success
    assert_select "input[name='layers[0][font]']", count: 0
    assert_select "select[name='layers[0][font]']" do
      assert_select "option[value='MissingCurrent.ttf'][selected='selected']", text: "Missing/current: MissingCurrent.ttf (Missing)"
      assert_select "option[value='GlobalBrand.ttf']", text: "GlobalBrand.ttf (Global)"
      assert_select "option[value='LegacyProject.ttf']", text: "LegacyProject.ttf (Project)"
    end
    assert_select "a[href='#global-font-upload-form'][data-open-font-library='true']", text: "Upload new font"
    assert_select ".font-field .field-help", text: "Upload fonts once to the global library, then select them here."
    assert_select "details#font-library-manager[data-persist-details-key='font-library-manager']"
    assert_select "details#font-library.font-library-panel[open]"
    assert_select "details#font-library-manager[open]"
    assert_select "form#global-font-upload-form[data-upload-kind='global-fonts']"
    assert_select "input#global-font-file-input[data-global-font-file-input='true']"
  end

  test "global font update and delete redirect back to font library anchor" do
    project = create_project
    asset = create_global_font_asset("GlobalBrand.ttf")

    patch update_global_font_asset_image_project_path(project, asset_id: asset.id), params: {
      global_font_asset: { match_name: "UpdatedBrand" }
    }

    assert_redirected_to image_project_path(project, task_index: 0, anchor: "font-library")
    assert_equal "UpdatedBrand", asset.reload.match_name

    delete global_font_asset_image_project_path(project, asset_id: asset.id)

    assert_redirected_to image_project_path(project, task_index: 0, anchor: "font-library")
    refute GlobalFontAsset.exists?(asset.id)
  end

  test "project page shows imported task names workflow actions and collapsed advanced sections" do
    project = create_project
    project.update_config!(
      "projectName" => "Uploads",
      "canvasDefaults" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [
        task_config("P1"),
        task_config("P2")
      ]
    )

    project.image_generation_jobs.create!(status: "completed")

    get image_project_path(project)

    assert_response :success
    assert_includes response.body, "Import Excel"
    assert_includes response.body, "Upload Images"
    assert_select ".project-layout"
    assert_select ".project-sidebar > .workflow-panel + .task-panel + .side-stack"
    assert_select ".project-sidebar > .workflow-panel > .workflow-step", count: 3
    assert_select ".project-sidebar > .workflow-panel > .workflow-step:nth-child(1) .step-label", text: "Step 1"
    assert_select ".project-sidebar > .workflow-panel > .workflow-step:nth-child(1) h2", text: "Import Excel"
    assert_select ".project-sidebar > .workflow-panel > .workflow-step:nth-child(2) .step-label", text: "Step 2"
    assert_select ".project-sidebar > .workflow-panel > .workflow-step:nth-child(2) h2", text: "Upload Images"
    assert_select ".project-sidebar > .workflow-panel > .workflow-step:nth-child(3) .step-label", text: "Step 3"
    assert_select ".project-sidebar > .workflow-panel > .workflow-step:nth-child(3) h2", text: "Preview / Download"
    assert_select ".workflow-step h2", text: "Upload Fonts", count: 0
    assert_select ".workflow-step .step-label", text: "Step 4", count: 0
    assert_select ".workflow-step .step-label", text: "Step 5", count: 0
    assert_select ".workflow-panel form.workflow-form[data-upload-reminder='true']", count: 2
    assert_select "form[data-upload-kind='excel'][data-upload-pending-label='Import Excel Now']"
    assert_select "form[data-upload-kind='images'][data-upload-action='Upload'][data-upload-singular='Image'][data-upload-plural='Images']"
    assert_select "form[data-upload-kind='fonts']", count: 0
    assert_select "details#font-library-manager"
    assert_select "form#global-font-upload-form[data-upload-kind='global-fonts'][data-upload-action='Upload'][data-upload-singular='Font'][data-upload-plural='Fonts']"
    assert_select "input#global-font-file-input[data-global-font-file-input='true']"
    assert_select ".upload-reminder-message[hidden][data-upload-reminder-message]", text: "File selected but not uploaded yet.", count: 3
    assert_select ".project-sidebar > .task-panel h2", text: "Select Task"
    assert_select ".task-title", text: "P1"
    assert_select ".task-title", text: "P2"
    assert_select "a.task-select-card[aria-current='page'][href='#{image_project_path(project, task_index: 0)}']"
    assert_select "a.task-select-card[href='#{image_project_path(project, task_index: 1)}']"
    assert_includes response.body, "Save &amp; Preview"
    assert_includes response.body, "Preview Selected Image"
    assert_includes response.body, "Preview All Images"
    assert_includes response.body, "Generate ZIP (All Images)"
    assert_select ".project-sidebar > .side-stack > details.warnings-panel + details.required-images-panel + details.font-library-panel + details.advanced-panel + details.danger-zone"
    assert_select ".project-sidebar > .side-stack > details.sidebar-details", count: 5
    assert_select ".project-sidebar details.warnings-panel summary", text: /Warnings \/ Errors/
    assert_select ".project-sidebar details.required-images-panel summary", text: /Required Images/
    assert_select ".project-sidebar details.font-library-panel summary", text: /Font Library/
    assert_select ".project-sidebar details.advanced-panel summary", text: /Advanced JSON/
    assert_select ".project-sidebar details.danger-zone summary", text: /Danger Zone/
    assert_select ".project-content > .preview-panel + .editor-panel"
    assert_select ".project-content .preview-panel h2", text: "Preview for P1"
    assert_select ".project-content .editor-panel h2", text: "Selected Image Settings: P1"
    assert_select "details.warnings-panel[open]", count: 0
    assert_select "details.required-images-panel[open]", count: 0
    assert_select "details#font-library.font-library-panel[open]", count: 0
    assert_select "details.advanced-panel[open]", count: 0
    assert_select "details.danger-zone[open]", count: 0
    assert_select "details.warnings-panel.has-warnings", count: 0
    assert_select "details.warnings-panel.has-errors", count: 0
    refute_includes response.body, "Latest Generation"
    refute_includes response.body, "Generate P1"
    refute_includes response.body, "Generate All Images"
    assert_select "form#task-editor-form[action='#{image_project_path(project)}']"
    assert_select "form#task-editor-form input[name='_method'][value='patch']"
    assert_select ".form-toolbar button[type='submit'][name='after_save_action'][value='preview_current'][data-processing-label]", text: "Save & Preview"
    assert_select ".form-toolbar button[type='submit'][name='after_save_action'][value='preview_current'][formaction]", count: 0
    assert_select ".workflow-actions form", count: 0
    assert_select ".generate-step button[type='submit'][form='task-editor-form'][name='after_save_action'][value='preview_current'][data-processing-label='Generating preview...'][data-operation-action='selected-preview']", text: "Preview Selected Image"
    assert_select ".generate-step button[type='submit'][form='task-editor-form'][name='after_save_action'][value='preview_all'][data-processing-label='Generating all previews...'][data-operation-action='preview-all']", text: "Preview All Images"
    assert_select "button[type='submit'][form='task-editor-form'][name='after_save_action'][value='preview_all'][formaction]", count: 0
    assert_select ".generate-step button[type='submit'][form='task-editor-form'][name='after_save_action'][value='download_zip'][data-processing-label='Generating images and preparing ZIP...'][data-operation-action='zip']", text: "Generate ZIP (All Images)"
    assert_select "button[type='submit'][form='task-editor-form'][name='after_save_action'][value='generate_current']", count: 0
    assert_select "button[type='submit'][form='task-editor-form'][name='after_save_action'][value='generate_all']", count: 0
    assert_includes response.body, "Selected Image: <strong>P1</strong>"
    assert_includes response.body, "Preview is scaled for browser display."
    assert_includes response.body, "Final output size: <strong>1650 x 2480</strong>"
    assert_select "select[name='task[layoutMode]'] option[selected='selected'][value='strict']", text: "Strict Excel values"
    assert_includes response.body, "Danger Zone"
    assert_includes response.body, "Clear imported Excel data, uploaded images, previews, generated images, and ZIPs. Font Library will be kept."
    assert_includes response.body, "Delete this project and all uploaded/generated files. This cannot be undone."
    assert_select "details.advanced-panel[data-persist-details-key='advanced-json'] summary", text: /Advanced JSON/
    assert_select "details.layers-panel[data-persist-details-key='fine-tune-layers'] summary", text: /Fine-tune Layers/
    assert_select "details.layers-panel[open]", count: 0
    assert_select ".operation-bar", count: 0
    assert_select ".danger-zone a[href='#{clear_data_confirmation_image_project_path(project, return_to: image_project_path(project, task_index: 0))}']", text: "Clear project data"
    assert_select ".danger-zone a[href='#{delete_confirmation_image_project_path(project, return_to: image_project_path(project, task_index: 0))}']", text: "Delete Project"
    assert_select "details#font-library.font-library-panel"
  end

  test "blank project disables preview and download actions with helper text" do
    project = create_project

    get image_project_path(project)

    assert_response :success
    assert_select "button[name='after_save_action'][value='preview_current'][disabled='disabled']", text: "Preview Selected Image"
    assert_select "button[name='after_save_action'][value='preview_all'][disabled='disabled']", text: "Preview All Images"
    assert_select "button[name='after_save_action'][value='download_zip'][disabled='disabled']", text: "Generate ZIP (All Images)"
    assert_includes response.body, "Add at least one layer before previewing."
    assert_includes response.body, "Import Excel or add at least one renderable layer before downloading the ZIP."
  end

  test "blank project preview is rejected server side" do
    project = create_project
    renderer_factory = lambda { |_project| flunk "blank preview should not render" }

    with_singleton_method_stub(ImageProjects::Renderer, :new, renderer_factory) do
      post preview_image_project_path(project)
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    refute project.reload.preview_file.attached?
    follow_redirect!
    assert_includes response.body, "Please import Excel or add layers before previewing."
  end

  test "blank project preview all is rejected server side without rendering" do
    project = create_project
    renderer_factory = lambda { |_project| flunk "blank preview all should not render" }

    assert_no_difference -> { project.task_previews.count } do
      with_singleton_method_stub(ImageProjects::Renderer, :new, renderer_factory) do
        post preview_all_image_project_path(project)
      end
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "No previewable tasks found. Please import Excel or add layers before previewing."
  end

  test "blank project download is rejected server side without generation output" do
    project = create_project
    runner = lambda { |_project, **_kwargs| flunk "blank download should not generate" }

    assert_no_difference -> { project.image_generation_jobs.count } do
      with_singleton_method_stub(ImageProjects::GenerationRunner, :call, runner) do
        get download_zip_image_project_path(project)
      end
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "Please import Excel or add layers before downloading the ZIP."
  end

  test "preview autosave with no renderable layers is rejected server side" do
    project = create_project
    renderer_factory = lambda { |_project| flunk "blank preview autosave should not render" }

    with_singleton_method_stub(ImageProjects::Renderer, :new, renderer_factory) do
      patch image_project_path(project), params: editor_params(
        layer: text_layer_params("font" => "", "text" => ""),
        after_save_action: "preview_current"
      )
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    refute project.reload.preview_file.attached?
    follow_redirect!
    assert_includes response.body, "Please import Excel or add renderable layers before previewing."
  end

  test "preview all autosave with no renderable layers is rejected server side" do
    project = create_project
    renderer_factory = lambda { |_project| flunk "blank preview all autosave should not render" }

    assert_no_difference -> { project.task_previews.count } do
      with_singleton_method_stub(ImageProjects::Renderer, :new, renderer_factory) do
        patch image_project_path(project), params: editor_params(
          layer: text_layer_params("font" => "", "text" => ""),
          after_save_action: "preview_all"
        )
      end
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "No previewable tasks found. Please import Excel or add renderable layers before previewing."
  end

  test "download autosave with no renderable layers is rejected server side" do
    project = create_project
    runner = lambda { |_project, **_kwargs| flunk "blank download autosave should not generate" }

    assert_no_difference -> { project.image_generation_jobs.count } do
      with_singleton_method_stub(ImageProjects::GenerationRunner, :call, runner) do
        patch image_project_path(project), params: editor_params(
          layer: text_layer_params("font" => "", "text" => ""),
          after_save_action: "download_zip"
        )
      end
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "Please import Excel or add layers before downloading the ZIP."
  end

  test "text only renderable task enables preview and download actions" do
    project = create_project
    task = task_config("Text Only")
    task["layers"] = [ text_layer_config.merge("font" => "", "text" => "Renderable text") ]
    project.update_config!("projectName" => "Uploads", "tasks" => [ task ])

    get image_project_path(project)

    assert_response :success
    assert_select "button[name='after_save_action'][value='preview_current'][disabled]", count: 0
    assert_select "button[name='after_save_action'][value='preview_all'][disabled]", count: 0
    assert_select "button[name='after_save_action'][value='download_zip'][disabled]", count: 0
  end

  test "image layer with missing source disables preview and download and is rejected server side" do
    project = create_project
    task = task_config("P2")
    task["layers"] = [
      {
        "id" => "layer0",
        "name" => "Main Image",
        "type" => "image",
        "imageName" => "P2",
        "width" => 800,
        "height" => 800,
        "x" => "center",
        "y" => 0,
        "fit" => "contain",
        "opacity" => 1
      }
    ]
    project.update_config!("projectName" => "Uploads", "tasks" => [ task ])

    get image_project_path(project)

    assert_response :success
    assert_select "button[name='after_save_action'][value='preview_current'][disabled='disabled']"
    assert_select "button[name='after_save_action'][value='preview_all'][disabled='disabled']"
    assert_select "button[name='after_save_action'][value='download_zip'][disabled='disabled']"
    assert_includes response.body, "Upload the required source images before previewing: P2."
    assert_includes response.body, "Upload the required source images before downloading the ZIP: P2."
    assert_select "details.warnings-panel.has-errors[open]"
    assert_select "details.required-images-panel.has-missing[open]" do
      assert_select "h2", text: "Required Images"
      assert_select "h3", text: "Image Assets"
    end

    post preview_image_project_path(project)
    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "Please upload the required source images before previewing."
  end

  test "image layer with attached matching source enables preview and download actions" do
    project = create_project
    attach_image_asset(project, "p2.png", alias_name: "P2")
    task = task_config("P2")
    task["layers"] = [
      {
        "id" => "layer0",
        "name" => "Main Image",
        "type" => "image",
        "imageName" => "P2",
        "width" => 800,
        "height" => 800,
        "x" => "center",
        "y" => 0,
        "fit" => "contain",
        "opacity" => 1
      }
    ]
    project.update_config!("projectName" => "Uploads", "tasks" => [ task ])

    get image_project_path(project)

    assert_response :success
    assert_select "button[name='after_save_action'][value='preview_current'][disabled]", count: 0
    assert_select "button[name='after_save_action'][value='preview_all'][disabled]", count: 0
    assert_select "button[name='after_save_action'][value='download_zip'][disabled]", count: 0
  end

  test "project page explains letter spacing and toggles target text width by mode" do
    project = create_project
    ratio_task = task_config("P1")
    ratio_task["layers"] = [ text_layer_config ]
    spread_task = task_config("P2")
    spread_layer = text_layer_config.merge(
      "letterSpacingMode" => "spread",
      "targetTextWidthRatio" => 0.78
    )
    spread_task["layers"] = [ spread_layer ]
    project.update_config!(
      "projectName" => "Uploads",
      "tasks" => [ ratio_task, spread_task ]
    )

    get image_project_path(project, task_index: 0)

    assert_response :success
    assert_includes response.body, "0.3 means 30% of font size. With font size 80, 0.3 = 24px."
    assert_includes response.body, "Large values such as 0.65 create very wide tracking."
    assert_select "select[name='layers[0][letterSpacingMode]'][data-letter-spacing-mode-source='true'][data-action='change->conditional-sections#update']"
    assert_select "#layer-0-target-text-width-ratio-field[data-letter-spacing-mode-section='spread']"
    assert_select "#layer-0-target-text-width-ratio-field[hidden]"
    assert_select "#layer-0-target-text-width-ratio-field input[name='layers[0][targetTextWidthRatio]'][disabled='disabled']"

    get image_project_path(project, task_index: 1)

    assert_response :success
    assert_select "#layer-0-target-text-width-ratio-field[hidden]", count: 0
    assert_select "#layer-0-target-text-width-ratio-field input[name='layers[0][targetTextWidthRatio]'][disabled]", count: 0
    assert_select "#layer-0-target-text-width-ratio-field input[name='layers[0][targetTextWidthRatio]'][value='0.78']"
  end

  test "project page renders layer type sections for image and text layers" do
    project = create_project
    task = task_config("P1")
    task["layers"] = [
      {
        "id" => "layer0",
        "name" => "Main Image",
        "type" => "image",
        "imageName" => "p1",
        "width" => 800,
        "height" => 900,
        "x" => "center",
        "y" => 0,
        "fit" => "contain",
        "opacity" => 1
      },
      text_layer_config
    ]
    project.update_config!(
      "projectName" => "Uploads",
      "tasks" => [ task ]
    )

    get image_project_path(project)

    assert_response :success
    assert_select "article.layer-card[data-controller='conditional-sections'][data-conditional-sections-section-attribute-value='layer-type-section']", count: 2
    assert_select "select[name='layers[0][type]'][data-layer-type-source='true'][data-action='change->conditional-sections#update'] option[selected='selected'][value='image']"
    assert_select "label[data-layer-type-section='image'] input[name='layers[0][imageName]'][value='p1']"
    assert_select "label[data-layer-type-section='text'][hidden] textarea[name='layers[0][text]']"
    assert_select "select[name='layers[1][type]'][data-layer-type-source='true'] option[selected='selected'][value='text']"
    assert_select "label[data-layer-type-section='text'] textarea[name='layers[1][text]']", text: "Original title"
    assert_select "label[data-layer-type-section='image'][hidden] input[name='layers[1][imageName]']"
    assert_includes response.body, "Inline formatting supported: **bold** and *italic*. Example: **DESIGN** HIGHLIGHTS"
    assert_includes response.body, "Whole-layer Bold affects all text. For only one word, use **word** in Text Content."
    assert_includes response.body, "Import Notes"
    assert_includes response.body, "Notes are parsed only during Excel import. Editing this field later will not change positioning, spacing, font, or other render settings. To change the output, edit the fields above."
  end

  test "project page shows readiness checklist for matched and missing assets" do
    project = create_project
    project.image_assets.create!(
      name: "p1.png",
      alias_name: "p1",
      normalized_name: "p1",
      width: 1650,
      height: 2480
    )
    create_global_font_asset("GenWanMinTW-Light.ttf", match_name: "GenWanMinTW-Light")
    p1 = task_config("P1")
    p1["layers"] = [
      { "id" => "layer0", "type" => "image", "imageName" => "p1" },
      { "id" => "layer1", "type" => "text", "font" => "GenWanMinTW-Light.ttf" }
    ]
    p2 = task_config("P2")
    p2["layers"] = [
      { "id" => "layer0", "type" => "image", "imageName" => "P2" },
      { "id" => "layer1", "type" => "text", "font" => "AlibabaPuHuiTi-3-55-Regular" }
    ]
    project.update_config!(
      "projectName" => "Uploads",
      "canvasDefaults" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [ p1, p2 ]
    )

    get image_project_path(project)

    assert_response :success
    assert_select ".task-title", text: "P1"
    assert_select ".task-title", text: "P2"
    assert_includes response.body, "p1 matched to p1.png"
    assert_includes response.body, "P2 missing"
    assert_includes response.body, "GenWanMinTW-Light.ttf matched to GenWanMinTW-Light.ttf"
    refute_includes response.body, "Font &quot;GenWanMinTW-Light.ttf&quot; was not uploaded."
    assert_includes response.body, "Font &quot;AlibabaPuHuiTi-3-55-Regular&quot; was not uploaded. A fallback font was used, so the generated image may not visually match the expected design."
    assert_includes response.body, "Font Library"
    assert_includes response.body, "Required Fonts"
    assert_select "details#font-library.font-library-panel.has-missing[open]"
    assert_select "details#font-library-manager[open]"
  end

  test "fileless global font record does not clear readiness warning" do
    project = create_project
    GlobalFontAsset.create!(
      name: "FilelessBrand.ttf",
      match_name: "FilelessBrand",
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless("FilelessBrand.ttf")
    )
    task = task_config("P1")
    task["layers"] = [
      { "id" => "layer1", "type" => "text", "font" => "FilelessBrand.ttf" }
    ]
    project.update_config!(
      "projectName" => "Uploads",
      "tasks" => [ task ]
    )

    get image_project_path(project)

    assert_response :success
    assert_includes response.body, "Font &#39;FilelessBrand.ttf&#39; matched &#39;FilelessBrand.ttf&#39;, but that font record has no attached file. A fallback font was used."
    refute_includes response.body, "FilelessBrand.ttf matched to FilelessBrand.ttf"
    assert_select "details#font-library.font-library-panel.has-missing[open]"
    assert_select "details#font-library-manager[open]"
  end

  test "saving editor preserves spread title settings and applies P1 off-white default color" do
    project = create_project
    project.update_config!(
      "projectName" => "Uploads",
      "canvasDefaults" => { "width" => 1650, "height" => 2480, "backgroundColor" => "transparent", "transparent" => true, "outputFormat" => "png" },
      "tasks" => [ task_config("P1") ]
    )

    patch image_project_path(project), params: {
      task_index: 0,
      image_project: { name: "Uploads" },
      task: {
        targetName: "P1",
        layoutMode: "design",
        canvas: { width: "1650", height: "2480", backgroundColor: "transparent", transparent: "1" },
        output: { width: "1650", height: "2480", format: "png" }
      },
      layers: {
        "0" => {
          id: "layer0",
          name: "Main Image",
          type: "image",
          imageName: "p1",
          width: "1650",
          height: "2480",
          fit: "cover",
          x: "center",
          y: "0",
          opacity: "1"
        },
        "1" => {
          id: "layer1",
          name: "Title",
          type: "text",
          text: "留住温度 延长适饮",
          font: "GenWanMinTW-Light.ttf",
          fontSize: "80",
          color: "",
          letterSpacingRatio: "0.65",
          lineHeightRatio: "1.2",
          maxWidth: "1650",
          autoWrap: "1",
          bold: "0",
          italic: "0",
          align: "center",
          letterSpacingMode: "spread",
          targetTextWidthRatio: "0.78",
          x: "center",
          y: "200",
          opacity: "1",
          notes: ""
        }
      }
    }

    assert_redirected_to image_project_path(project, task_index: 0)
    config = project.reload.config_hash
    title = config.dig("tasks", 0, "layers", 1)
    assert_equal "design", config["layoutMode"]
    assert_equal "#F4EAD7", title["color"]
    assert_equal "spread", title["letterSpacingMode"]
    assert_in_delta 0.78, title["targetTextWidthRatio"], 0.001
  end

  test "saving editor clears spread title settings when ratio mode is submitted" do
    project = create_project
    task = task_config("P1")
    task["layers"] = [
      {
        "id" => "layer0",
        "name" => "Title",
        "type" => "text",
        "text" => "Original title",
        "font" => "Brand.ttf",
        "fontSize" => 80,
        "color" => "#111111",
        "letterSpacingRatio" => 0.4,
        "letterSpacingMode" => "spread",
        "targetTextWidthRatio" => 0.78,
        "lineHeightRatio" => 1.2,
        "maxWidth" => 1200,
        "autoWrap" => true,
        "bold" => false,
        "italic" => false,
        "x" => "center",
        "y" => 200,
        "align" => "center",
        "opacity" => 1,
        "notes" => ""
      }
    ]
    project.update_config!(
      "projectName" => "Uploads",
      "tasks" => [ task ]
    )

    patch image_project_path(project), params: editor_params(
      layer: text_layer_params(
        "letterSpacingRatio" => "0.12",
        "letterSpacingMode" => "",
        "targetTextWidthRatio" => "0.78"
      )
    )

    assert_redirected_to image_project_path(project, task_index: 0)
    title = project.reload.config_hash.dig("tasks", 0, "layers", 0)
    refute title.key?("letterSpacingMode")
    refute title.key?("targetTextWidthRatio")
    assert_in_delta 0.12, title["letterSpacingRatio"], 0.001
  end

  test "saving editor preserves relative positioning and lets offset control placement" do
    project = create_project
    task = task_config("P1")
    task["layers"] = relative_position_layers
    project.update_config!(
      "projectName" => "Uploads",
      "tasks" => [ task ]
    )

    patch image_project_path(project), params: relative_editor_params(
      project,
      relative_layer_overrides: {
        "relativeOffset" => "180",
        "y" => "999",
        "notes" => "Do not reparse this note into layout"
      }
    )

    assert_redirected_to image_project_path(project, task_index: 0)
    body = project.reload.config_hash.dig("tasks", 0, "layers", 1)
    assert_equal "layer0", body["relativeTo"]
    assert_equal "below", body["relativePosition"]
    assert_equal 180, body["relativeOffset"]
    assert_equal 999, body["y"]
    assert_equal 380, ImageProjects::Renderer.new(project).resolved_layers_for(project.tasks.first)[1]["y"]
  end

  test "switch to absolute positioning clears relative fields and lets y control placement" do
    project = create_project
    task = task_config("P1")
    task["layers"] = relative_position_layers
    project.update_config!(
      "projectName" => "Uploads",
      "tasks" => [ task ]
    )

    patch image_project_path(project), params: relative_editor_params(
      project,
      relative_layer_overrides: { "relativeOffset" => "180", "y" => "0" },
      editor_operation: "switch_to_absolute:1"
    )

    assert_redirected_to image_project_path(project, task_index: 0)
    body = project.reload.config_hash.dig("tasks", 0, "layers", 1)
    refute body.key?("relativeTo")
    refute body.key?("relativePosition")
    refute body.key?("relativeOffset")
    assert_equal "layer0", body["previousRelativeTo"]
    assert_equal "below", body["previousRelativePosition"]
    assert_equal 180, body["previousRelativeOffset"]
    assert_equal 380, body["y"]

    patch image_project_path(project), params: relative_editor_params(
      project,
      include_relative_fields: false,
      relative_layer_overrides: { "y" => "420" }
    )

    assert_redirected_to image_project_path(project, task_index: 0)
    body = project.reload.config_hash.dig("tasks", 0, "layers", 1)
    refute body.key?("relativeTo")
    assert_equal 420, body["y"]
    assert_equal 420, ImageProjects::Renderer.new(project).resolved_layers_for(project.tasks.first)[1]["y"]

    patch image_project_path(project), params: relative_editor_params(
      project,
      include_relative_fields: false,
      editor_operation: "switch_to_relative:1"
    )

    assert_redirected_to image_project_path(project, task_index: 0)
    body = project.reload.config_hash.dig("tasks", 0, "layers", 1)
    assert_equal "layer0", body["relativeTo"]
    assert_equal "below", body["relativePosition"]
    assert_equal 180, body["relativeOffset"]
    assert_equal 380, ImageProjects::Renderer.new(project).resolved_layers_for(project.tasks.first)[1]["y"]

    patch image_project_path(project), params: relative_editor_params(
      project,
      relative_layer_overrides: { "relativeOffset" => "240", "y" => "999" }
    )

    assert_redirected_to image_project_path(project, task_index: 0)
    body = project.reload.config_hash.dig("tasks", 0, "layers", 1)
    assert_equal 240, body["relativeOffset"]
    assert_equal 440, ImageProjects::Renderer.new(project).resolved_layers_for(project.tasks.first)[1]["y"]
  end

  test "editing import notes on normal save does not reparse render settings" do
    project = create_project
    task = task_config("P1")
    task["layers"] = [ text_layer_config ]
    project.update_config!(
      "projectName" => "Uploads",
      "tasks" => [ task ]
    )

    patch image_project_path(project), params: editor_params(
      layer: text_layer_params(
        "letterSpacingRatio" => "0.4",
        "notes" => "letter spacing 90% and 120 px below layer 0"
      )
    )

    assert_redirected_to image_project_path(project, task_index: 0)
    title = project.reload.config_hash.dig("tasks", 0, "layers", 0)
    assert_in_delta 0.4, title["letterSpacingRatio"], 0.001
    refute title.key?("relativeTo")
    assert_equal "letter spacing 90% and 120 px below layer 0", title["notes"]
  end

  test "saving editor without after save action does not preview or generate" do
    project = create_project
    task = task_config("P1")
    task["layers"] = [ text_layer_config ]
    project.update_config!(
      "projectName" => "Uploads",
      "tasks" => [ task ]
    )

    renderer_factory = lambda do |*_args|
      flunk "save-only update should not instantiate preview renderer"
    end
    runner = lambda do |*_args, **_kwargs|
      flunk "save-only update should not run generation"
    end

    with_singleton_method_stub(ImageProjects::Renderer, :new, renderer_factory) do
      with_singleton_method_stub(ImageProjects::GenerationRunner, :call, runner) do
        patch image_project_path(project), params: editor_params(
          layer: text_layer_params("text" => "Saved only")
        )
      end
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal "Saved only", project.reload.config_hash.dig("tasks", 0, "layers", 0, "text")
  end

  test "saving editor preserves inline markup" do
    project = create_project
    task = task_config("P1")
    task["layers"] = [ text_layer_config.merge("font" => "") ]
    project.update_config!(
      "projectName" => "Uploads",
      "tasks" => [ task ]
    )

    patch image_project_path(project), params: editor_params(
      layer: text_layer_params("font" => "", "text" => "**DESIGN** HIGHLIGHTS")
    )

    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal "**DESIGN** HIGHLIGHTS", project.reload.config_hash.dig("tasks", 0, "layers", 0, "text")
  end

  test "project index shows delete action" do
    project = create_project
    updated_at = Time.utc(2026, 6, 19, 7, 19, 0)
    project.update_columns(updated_at: updated_at)

    get image_projects_path

    assert_response :success
    assert_includes response.body, project.name
    assert_select "a[href='#{delete_confirmation_image_project_path(project, return_to: image_projects_path)}']", text: "Delete"
    assert_select "time[data-local-time='true'][datetime='#{updated_at.iso8601}'][title='UTC: #{updated_at.iso8601}']", text: "19 Jun 07:19 UTC"
    assert_equal updated_at.iso8601, project.reload.updated_at.utc.iso8601
  end

  test "delete confirmation page displays project summary" do
    project = project_with_delete_summary_data

    get delete_confirmation_image_project_path(project, return_to: image_projects_path)

    assert_response :success
    assert_includes response.body, "This action cannot be undone."
    assert_select "table.delete-summary-table" do
      assert_select "th", text: "Project name"
      assert_select "td", text: project.name
      assert_select "th", text: "Status"
      assert_select "td", text: project.status
      assert_select "th", text: "Number of tasks"
      assert_select "td", text: "2"
      assert_select "th", text: "Uploaded image assets count"
      assert_select "td", text: "1"
      assert_select "th", text: "Cached task previews count"
      assert_select "td", text: "1"
      assert_select "th", text: "Generated jobs / ZIP files count"
      assert_select "td", text: "2 jobs / 1 ZIP file"
      assert_select "th", text: "Last updated time"
      updated_at = project.updated_at.utc
      assert_select "td time[data-local-time='true'][datetime='#{updated_at.iso8601}'][title='UTC: #{updated_at.iso8601}']", text: updated_at.strftime(ApplicationHelper::LOCAL_TIME_FALLBACK_FORMAT)
    end
    assert_select "input[name='confirm_project_name']"
    assert_select "input[type='submit'][value='Yes, delete this project']"
    assert_select "a[href='#{image_projects_path}']", text: "Cancel"
  end

  test "clear project data confirmation page displays reset summary" do
    project = project_with_delete_summary_data

    get clear_data_confirmation_image_project_path(project, return_to: image_project_path(project))

    assert_response :success
    assert_includes response.body, "Clear Project Data"
    assert_includes response.body, "Font Library assets are kept."
    assert_select "table.delete-summary-table" do
      assert_select "th", text: "Project name"
      assert_select "td", text: project.name
      assert_select "th", text: "Number of tasks"
      assert_select "td", text: "2"
      assert_select "th", text: "Uploaded image assets count"
      assert_select "td", text: "1"
      assert_select "th", text: "Cached task previews count"
      assert_select "td", text: "1"
      assert_select "th", text: "ZIP attachments count"
      assert_select "td", text: "1"
      assert_select "th", text: "Global Font Library assets kept"
      updated_at = project.updated_at.utc
      assert_select "th", text: "Last updated time"
      assert_select "td time[data-local-time='true'][datetime='#{updated_at.iso8601}'][title='UTC: #{updated_at.iso8601}']", text: updated_at.strftime(ApplicationHelper::LOCAL_TIME_FALLBACK_FORMAT)
    end
    assert_select "input[name='confirm_clear']"
    assert_select "input[type='submit'][value='Clear project data']"
    assert_select "a[href='#{image_project_path(project)}']", text: "Cancel"
  end

  test "delete project route rejects missing and wrong confirmation name" do
    project = create_project

    assert_no_difference -> { ImageProject.count } do
      delete image_project_path(project)
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Type the project name exactly to confirm deletion."
    assert ImageProject.exists?(project.id)

    assert_no_difference -> { ImageProject.count } do
      delete image_project_path(project), params: { confirm_project_name: "Wrong Project" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Type the project name exactly to confirm deletion."
    assert ImageProject.exists?(project.id)
  end

  test "delete project route removes project with matching confirmation name" do
    project = create_project

    assert_difference -> { ImageProject.count }, -1 do
      delete image_project_path(project), params: { confirm_project_name: project.name }
    end

    assert_redirected_to image_projects_path
    refute ImageProject.exists?(project.id)
  end

  test "clear project data route requires exact CLEAR confirmation" do
    project = project_with_delete_summary_data

    assert_no_difference -> { project.reload.image_assets.count } do
      delete clear_project_data_image_project_path(project)
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Type CLEAR to confirm clearing project data."

    assert_no_difference -> { project.reload.image_assets.count } do
      delete clear_project_data_image_project_path(project), params: { confirm_clear: "clear" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Type CLEAR to confirm clearing project data."
  end

  test "clear project data route resets content while keeping project and font assets" do
    project = project_with_delete_summary_data
    project_font = create_project_font_asset(project, "ProjectBrand.ttf")
    global_font = create_global_font_asset("GlobalBrand.ttf")

    assert_no_difference -> { ImageProject.count } do
      delete clear_project_data_image_project_path(project), params: { confirm_clear: "CLEAR" }
    end

    assert_redirected_to image_project_path(project)
    project.reload
    assert_equal "Uploads", project.name
    assert_equal "draft", project.status
    assert_equal [ "Task 1" ], project.tasks.map { |task| task["targetName"] }
    assert_equal 0, project.image_assets.count
    assert_equal 0, project.task_previews.count
    assert_equal 0, project.image_generation_jobs.count
    assert_equal 1, project.font_assets.count
    assert_equal project_font.id, project.font_assets.first.id
    assert global_font.reload.file.attached?
  end

  test "project page shows image and font asset match name controls" do
    project = create_project
    image = project.image_assets.create!(
      name: "Weixin Image_20260610.png",
      alias_name: "p1",
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless("Weixin Image_20260610.png"),
      width: 1650,
      height: 2480
    )
    font = project.font_assets.create!(
      name: "GenWanMinTW-Light.ttf",
      alias_name: "GenWanMinTW-Light",
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless("GenWanMinTW-Light.ttf")
    )

    get image_project_path(project)

    assert_response :success
    assert_includes response.body, image.name
    assert_includes response.body, "Dimensions: 1650 x 2480"
    assert_includes response.body, font.name
    assert_includes response.body, "Excel Match Name"
    assert_includes response.body, "If Excel says p1, this field should be p1."
    assert_select "input[name='image_asset[alias_name]'][value='p1']"
    assert_select "input[name='font_asset[alias_name]'][value='GenWanMinTW-Light']"
  end

  test "project page shows clear task-level missing image status" do
    project = create_project
    task = task_config("P2")
    task["layers"] = [
      {
        "id" => "layer0",
        "name" => "Main Image",
        "type" => "image",
        "imageName" => "P2",
        "width" => 600,
        "height" => 600,
        "x" => "center",
        "y" => 500,
        "fit" => "contain",
        "opacity" => 1
      }
    ]
    project.update_config!(
      "projectName" => "Uploads",
      "canvasDefaults" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false, "outputFormat" => "png" },
      "tasks" => [ task ]
    )

    get image_project_path(project)

    assert_response :success
    assert_includes response.body, "missing image"
    assert_includes response.body, "Task P2 could not be generated because source image &quot;P2&quot; was not found."
  end

  test "upload with no selected file redirects with a clear alert" do
    project = create_project

    assert_no_difference -> { project.image_assets.count } do
      post upload_images_image_project_path(project), params: { images: [ "" ] }
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    follow_redirect!
    assert_includes response.body, "Image upload failed: Choose one or more files to upload."
  end

  test "upload ignores string nil and unsupported objects without reading original filename" do
    controller = ImageProjectsController.new
    controller.define_singleton_method(:params) do
      {
        images: [
          "",
          nil,
          "not a file",
          Object.new,
          ExplodingOriginalFilename.new
        ]
      }
    end

    assert_empty controller.send(:uploaded_files_for, :images)
  end

  test "upload normalizer accepts hash and parameters file collections" do
    hash_upload = uploaded_file("hash.png", "image/png")
    parameters_upload = uploaded_file("parameters.png", "image/png")
    controller = ImageProjectsController.new

    controller.define_singleton_method(:params) { { images: { "0" => "", "1" => hash_upload } } }
    assert_equal [ hash_upload ], controller.send(:uploaded_files_for, :images)

    controller.define_singleton_method(:params) do
      {
        images: ActionController::Parameters.new("0" => "", "1" => parameters_upload)
      }
    end
    assert_equal [ parameters_upload ], controller.send(:uploaded_files_for, :images)
  end

  private

  def create_project
    ImageProject.create!(name: "Uploads")
  end

  def project_with_delete_summary_data
    create_project.tap do |project|
      project.update_config!(
        "projectName" => "Uploads",
        "tasks" => [
          task_config("P1"),
          task_config("P2")
        ]
      )
      attach_image_asset(project, "p1.png", alias_name: "p1")
      task_preview = project.task_previews.create!(
        task_index: 0,
        task_name: "P1",
        input_signature: "signature",
        width: 1,
        height: 1,
        format: "png"
      )
      task_preview.file.attach(io: StringIO.new("preview"), filename: "preview.png", content_type: "image/png")
      zipped_job = project.image_generation_jobs.create!(status: "completed")
      zipped_job.zip_file.attach(io: StringIO.new("zip-bytes"), filename: "generated.zip", content_type: "application/zip")
      project.image_generation_jobs.create!(status: "failed")
      project.reload
    end
  end

  def create_global_font_asset(name, match_name: nil)
    asset = GlobalFontAsset.create!(
      name: name,
      match_name: match_name,
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    asset.file.attach(io: StringIO.new("font data"), filename: name, content_type: font_content_type(name))
    asset
  end

  def create_project_font_asset(project, name, alias_name: nil)
    asset = project.font_assets.create!(
      name: name,
      alias_name: alias_name,
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    asset.file.attach(io: StringIO.new("font data"), filename: name, content_type: font_content_type(name))
    asset
  end

  def font_content_type(name)
    "font/#{File.extname(name).delete(".")}"
  end

  def uploaded_file(filename, content_type)
    tempfile = Tempfile.new([ File.basename(filename, ".*"), File.extname(filename) ])
    tempfile.binmode
    tempfile.write("test upload")
    tempfile.rewind
    @tempfiles << tempfile

    Rack::Test::UploadedFile.new(tempfile.path, content_type, true, original_filename: filename)
  end

  def attach_image_asset(project, name, alias_name: nil)
    asset = project.image_assets.create!(
      name: name,
      alias_name: alias_name,
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name),
      width: 1,
      height: 1
    )
    asset.file.attach(io: StringIO.new("image data"), filename: name, content_type: "image/png")
    asset
  end

  def task_config(target_name)
    {
      "targetName" => target_name,
      "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
      "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
      "layers" => []
    }
  end

  def relative_position_layers
    [
      {
        "id" => "layer0",
        "name" => "Reference Image",
        "type" => "image",
        "imageName" => "",
        "width" => 300,
        "height" => 200,
        "x" => "center",
        "y" => 0,
        "fit" => "contain",
        "opacity" => 1,
        "notes" => ""
      },
      {
        "id" => "layer1",
        "name" => "Body",
        "type" => "text",
        "text" => "Relative body copy",
        "font" => "",
        "fontSize" => 40,
        "color" => "#111111",
        "letterSpacingRatio" => 0,
        "lineHeightRatio" => 1.2,
        "maxWidth" => 1200,
        "autoWrap" => true,
        "bold" => false,
        "italic" => false,
        "x" => "center",
        "y" => 0,
        "align" => "center",
        "opacity" => 1,
        "relativeTo" => "layer0",
        "relativePosition" => "below",
        "relativeOffset" => 120,
        "notes" => "Original Excel note"
      }
    ]
  end

  def relative_editor_params(project, relative_layer_overrides: {}, editor_operation: nil, include_relative_fields: true)
    task = project.reload.config_hash.dig("tasks", 0)
    reference = task.dig("layers", 0)
    body = task.dig("layers", 1)
    body_params = {
      "id" => body["id"],
      "name" => body["name"],
      "type" => body["type"],
      "text" => body["text"],
      "font" => body["font"],
      "fontSize" => body["fontSize"].to_s,
      "color" => body["color"],
      "letterSpacingRatio" => body["letterSpacingRatio"].to_s,
      "lineHeightRatio" => body["lineHeightRatio"].to_s,
      "maxWidth" => body["maxWidth"].to_s,
      "autoWrap" => body["autoWrap"] ? "1" : "0",
      "bold" => body["bold"] ? "1" : "0",
      "italic" => body["italic"] ? "1" : "0",
      "x" => body["x"],
      "y" => body["y"].to_s,
      "align" => body["align"],
      "opacity" => body["opacity"].to_s,
      "letterSpacingMode" => body["letterSpacingMode"].to_s,
      "targetTextWidthRatio" => (body["targetTextWidthRatio"] || 0.78).to_s,
      "notes" => body["notes"].to_s
    }
    if include_relative_fields
      body_params["relativeTo"] = body["relativeTo"]
      body_params["relativePosition"] = body["relativePosition"]
      body_params["relativeOffset"] = body["relativeOffset"].to_s if body.key?("relativeOffset")
    end
    body_params.merge!(relative_layer_overrides)

    params = {
      task_index: 0,
      image_project: { name: "Uploads" },
      task: {
        targetName: task["targetName"],
        layoutMode: task["layoutMode"].presence || "strict",
        canvas: {
          width: task.dig("canvas", "width").to_s,
          height: task.dig("canvas", "height").to_s,
          backgroundColor: task.dig("canvas", "backgroundColor"),
          transparent: task.dig("canvas", "transparent") ? "1" : "0"
        },
        output: {
          width: task.dig("output", "width").to_s,
          height: task.dig("output", "height").to_s,
          format: task.dig("output", "format")
        }
      },
      layers: {
        "0" => {
          "id" => reference["id"],
          "name" => reference["name"],
          "type" => reference["type"],
          "imageName" => reference["imageName"],
          "width" => reference["width"].to_s,
          "height" => reference["height"].to_s,
          "fit" => reference["fit"],
          "x" => reference["x"],
          "y" => reference["y"].to_s,
          "opacity" => reference["opacity"].to_s,
          "notes" => reference["notes"].to_s
        },
        "1" => body_params
      }
    }
    params[:editor_operation] = editor_operation if editor_operation
    params
  end

  def editor_params(layer:, after_save_action: nil)
    params = {
      task_index: 0,
      image_project: { name: "Uploads" },
      task: {
        targetName: "P1",
        layoutMode: "strict",
        canvas: { width: "1650", height: "2480", backgroundColor: "#FAFAF0", transparent: "0" },
        output: { width: "1650", height: "2480", format: "png" }
      },
      layers: {
        "0" => layer
      }
    }
    params[:after_save_action] = after_save_action if after_save_action
    params
  end

  def text_layer_config
    {
      "id" => "layer0",
      "name" => "Title",
      "type" => "text",
      "text" => "Original title",
      "font" => "Brand.ttf",
      "fontSize" => 80,
      "color" => "#111111",
      "letterSpacingRatio" => 0.4,
      "lineHeightRatio" => 1.2,
      "maxWidth" => 1200,
      "autoWrap" => true,
      "bold" => false,
      "italic" => false,
      "x" => "center",
      "y" => 200,
      "align" => "center",
      "opacity" => 1,
      "notes" => ""
    }
  end

  def text_layer_params(overrides = {})
    text_layer_config.merge(
      "fontSize" => "80",
      "letterSpacingRatio" => "0.4",
      "lineHeightRatio" => "1.2",
      "maxWidth" => "1200",
      "autoWrap" => "1",
      "bold" => "0",
      "italic" => "0",
      "y" => "200",
      "opacity" => "1",
      "letterSpacingMode" => "",
      "targetTextWidthRatio" => "0.78"
    ).merge(overrides)
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
end
