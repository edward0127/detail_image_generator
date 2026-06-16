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

  private

  def open_layers_panel
    find("details.layers-panel summary").click unless page.has_selector?("details.layers-panel[open]", wait: 0)
  end

  def within_layer(index, &block)
    within(all("article.layer-card", minimum: index + 1)[index], &block)
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
