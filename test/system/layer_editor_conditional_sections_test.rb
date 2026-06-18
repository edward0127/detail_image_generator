require "application_system_test_case"

class LayerEditorConditionalSectionsTest < ApplicationSystemTestCase
  test "rendered image and text layers initialise their visible fields" do
    project = layer_project

    visit image_project_path(project)
    open_layers_panel

    within_layer(0) do
      assert_image_fields_visible(0)
      assert_text_fields_hidden(0)
    end

    within_layer(1) do
      assert_text_fields_visible(1)
      assert_image_fields_hidden(1)
    end
  end

  test "changing layer type updates fields immediately" do
    project = layer_project

    visit image_project_path(project)
    open_layers_panel

    within_layer(0) do
      find("select[name='layers[0][type]']").select("text")
      assert_text_fields_visible(0)
      assert_image_fields_hidden(0)
    end

    within_layer(1) do
      find("select[name='layers[1][type]']").select("image")
      assert_image_fields_visible(1)
      assert_text_fields_hidden(1)
    end
  end

  test "newly added and copied layers use dynamic layer sections" do
    project = layer_project

    visit image_project_path(project)
    open_layers_panel
    click_button "Add Image Layer"

    open_layers_panel
    assert_selector "article.layer-card", count: 3
    within_layer(2) do
      assert_image_fields_visible(2)
      find("select[name='layers[2][type]']").select("text")
      assert_text_fields_visible(2)
      assert_image_fields_hidden(2)
    end

    within_layer(1) do
      click_button "Copy"
    end

    open_layers_panel
    assert_selector "article.layer-card", count: 4
    within_layer(2) do
      assert_text_fields_visible(2)
      find("select[name='layers[2][type]']").select("image")
      assert_image_fields_visible(2)
      assert_text_fields_hidden(2)
    end
  end

  test "letter spacing mode updates target width immediately" do
    project = layer_project

    visit image_project_path(project)
    open_layers_panel

    within_layer(1) do
      find("details.layer-advanced summary").click
      assert_field_hidden("layers[1][targetTextWidthRatio]")
      assert_selector "input[name='layers[1][targetTextWidthRatio]'][disabled]", visible: :all

      find("select[name='layers[1][letterSpacingMode]']").select("Spread to target width")
      assert_field_visible("layers[1][targetTextWidthRatio]")
      assert_no_selector "input[name='layers[1][targetTextWidthRatio]'][disabled]", visible: :all

      find("select[name='layers[1][letterSpacingMode]']").select("Ratio")
      assert_field_hidden("layers[1][targetTextWidthRatio]")
      assert_selector "input[name='layers[1][targetTextWidthRatio]'][disabled]", visible: :all
    end
  end

  test "relative positioning disables y and can switch to absolute positioning" do
    project = relative_layer_project

    visit image_project_path(project)
    open_layers_panel

    within_layer(1) do
      assert_text "Position"
      assert_text "Relative positioning"
      assert_text "This layer is positioned relative to another layer. Y is calculated automatically."
      assert_text "Reference Image / layer0"
      assert_text "Below"
      assert_selector "input[name='layers[1][y]'][disabled]", visible: true
      assert_field_visible("layers[1][relativeOffset]")

      fill_in "layers[1][relativeOffset]", with: "180"
      find("details.layer-advanced summary").click
      assert_selector "details.layer-advanced[open]"
      click_button "Switch to absolute"
    end

    assert_selector "details.layers-panel[open]"
    within_layer(1) do
      assert_selector "details.layer-advanced[open]"
      assert_text "Position"
      assert_text "Absolute positioning"
      assert_text "Use X and Y to place this layer directly on the canvas."
      assert_field_visible("layers[1][y]")
      assert_no_selector "input[name='layers[1][y]'][disabled]", visible: :all
      assert_no_selector "input[name='layers[1][relativeOffset]']", visible: :all
      assert_no_text "Switch to absolute"
      assert_button "Switch back to relative"
      click_button "Switch back to relative"
    end

    assert_selector "details.layers-panel[open]"
    within_layer(1) do
      assert_selector "details.layer-advanced[open]"
      assert_text "Relative positioning"
      assert_selector "input[name='layers[1][y]'][disabled]", visible: true
      assert_field_visible("layers[1][relativeOffset]")
      assert_text "Switch to absolute"
    end

    layer = project.reload.config_hash.dig("tasks", 0, "layers", 1)
    assert_equal "layer0", layer["relativeTo"]
    assert_equal "below", layer["relativePosition"]
    assert_equal 180, layer["relativeOffset"]
    assert_equal 1080, ImageProjects::Renderer.new(project).resolved_layers_for(project.tasks.first)[1]["y"]
  end

  test "editor operation restores scroll near edited layer" do
    project = many_relative_layer_project

    visit image_project_path(project)
    open_layers_panel
    scroll_layer_into_view(10)

    within_layer(10) do
      fill_in "layers[10][relativeOffset]", with: "210"
      assert_operator page.evaluate_script("window.scrollY"), :>, 0
      click_button "Switch to absolute"
    end

    assert_selector "details.layers-panel[open]"
    within_layer(10) do
      assert_button "Switch back to relative"
    end
    assert_operator page.evaluate_script("window.scrollY"), :>, 0
    assert_layer_in_view(10)
  end

  test "details persistence is scoped by project and task" do
    project = two_task_layer_project
    task_zero_key = editor_ui_state_key(project, 0)

    visit image_project_path(project, task_index: 0)
    open_layers_panel
    assert_equal true, page.evaluate_script("JSON.parse(sessionStorage.getItem('#{task_zero_key}')).details['fine-tune-layers']")

    visit image_project_path(project, task_index: 1)
    assert_no_selector "details.layers-panel[open]", wait: 0.5
    assert_nil page.evaluate_script("sessionStorage.getItem('#{editor_ui_state_key(project, 1)}')")

    visit image_project_path(project, task_index: 0)
    assert_selector "details.layers-panel[open]"
  end

  private

  def open_layers_panel
    find("details.layers-panel summary").click unless page.has_selector?("details.layers-panel[open]", wait: 0)
  end

  def within_layer(index, &block)
    within(all("article.layer-card", minimum: index + 1)[index], &block)
  end

  def scroll_layer_into_view(index)
    layer = all("article.layer-card", minimum: index + 1)[index]
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' });", layer)
  end

  def assert_layer_in_view(index)
    assert page.evaluate_script(<<~JS)
      (function() {
      var layer = document.querySelectorAll("article.layer-card")[#{index}];
      if (!layer) { return false; }
      var rect = layer.getBoundingClientRect();
      return rect.top < window.innerHeight && rect.bottom > 0;
      })();
    JS
  end

  def editor_ui_state_key(project, task_index)
    "image-project:#{project.id}:task:#{task_index}:editor-ui-state"
  end

  def assert_image_fields_visible(index)
    assert_field_visible("layers[#{index}][imageName]")
    assert_field_visible("layers[#{index}][width]")
    assert_field_visible("layers[#{index}][height]")
    assert_field_visible("layers[#{index}][fit]")
  end

  def assert_image_fields_hidden(index)
    assert_field_hidden("layers[#{index}][imageName]")
    assert_field_hidden("layers[#{index}][width]")
    assert_field_hidden("layers[#{index}][height]")
    assert_field_hidden("layers[#{index}][fit]")
  end

  def assert_text_fields_visible(index)
    assert_field_visible("layers[#{index}][text]")
    assert_field_visible("layers[#{index}][font]")
    assert_field_visible("layers[#{index}][fontSize]")
    assert_field_visible("layers[#{index}][color]")
    assert_field_visible("layers[#{index}][letterSpacingRatio]")
    assert_field_visible("layers[#{index}][lineHeightRatio]")
    assert_field_visible("layers[#{index}][maxWidth]")
    assert_field_visible("layers[#{index}][align]")
    assert_field_visible("layers[#{index}][autoWrap]")
  end

  def assert_text_fields_hidden(index)
    assert_field_hidden("layers[#{index}][text]")
    assert_field_hidden("layers[#{index}][font]")
    assert_field_hidden("layers[#{index}][fontSize]")
    assert_field_hidden("layers[#{index}][color]")
    assert_field_hidden("layers[#{index}][letterSpacingRatio]")
    assert_field_hidden("layers[#{index}][lineHeightRatio]")
    assert_field_hidden("layers[#{index}][maxWidth]")
    assert_field_hidden("layers[#{index}][align]")
    assert_field_hidden("layers[#{index}][autoWrap]")
  end

  def assert_field_visible(name)
    assert_selector field_selector(name), visible: true
  end

  def assert_field_hidden(name)
    assert_selector field_selector(name), visible: :all
    assert_no_selector field_selector(name), visible: true
  end

  def field_selector(name)
    "input[name='#{name}'], textarea[name='#{name}'], select[name='#{name}']"
  end

  def layer_project
    ImageProject.create!(name: "Layer UI").tap do |project|
      project.update_config!(
        "projectName" => "Layer UI",
        "tasks" => [
          {
            "targetName" => "P1",
            "layoutMode" => "strict",
            "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
            "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
            "layers" => [
              image_layer,
              text_layer
            ]
          }
        ]
      )
    end
  end

  def relative_layer_project
    ImageProject.create!(name: "Relative Layer UI").tap do |project|
      project.update_config!(
        "projectName" => "Relative Layer UI",
        "tasks" => [
          {
            "targetName" => "P1",
            "layoutMode" => "strict",
            "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
            "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
            "layers" => [
              image_layer.merge("name" => "Reference Image"),
              text_layer.merge(
                "name" => "Relative Body",
                "relativeTo" => "layer0",
                "relativePosition" => "below",
                "relativeOffset" => 120,
                "y" => 0,
                "notes" => "Original Excel position instruction"
              )
            ]
          }
        ]
      )
    end
  end

  def many_relative_layer_project
    ImageProject.create!(name: "Many Relative Layers").tap do |project|
      layers = [ image_layer.merge("name" => "Reference Image") ]
      1.upto(10) do |index|
        layers << text_layer.merge(
          "id" => "layer#{index}",
          "name" => "Relative Body #{index}",
          "text" => "Body #{index}",
          "relativeTo" => "layer0",
          "relativePosition" => "below",
          "relativeOffset" => 100 + index,
          "y" => 0
        )
      end

      project.update_config!(
        "projectName" => "Many Relative Layers",
        "tasks" => [
          {
            "targetName" => "P1",
            "layoutMode" => "strict",
            "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
            "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
            "layers" => layers
          }
        ]
      )
    end
  end

  def two_task_layer_project
    ImageProject.create!(name: "Scoped Details").tap do |project|
      project.update_config!(
        "projectName" => "Scoped Details",
        "tasks" => [
          layer_task("P1"),
          layer_task("P2")
        ]
      )
    end
  end

  def layer_task(target_name)
    {
      "targetName" => target_name,
      "layoutMode" => "strict",
      "canvas" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
      "output" => { "width" => 1650, "height" => 2480, "format" => "png" },
      "layers" => [
        image_layer,
        text_layer.merge("text" => "#{target_name} title")
      ]
    }
  end

  def image_layer
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
    }
  end

  def text_layer
    {
      "id" => "layer1",
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
end
