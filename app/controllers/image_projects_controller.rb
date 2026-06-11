class ImageProjectsController < ApplicationController
  before_action :set_image_project, except: %i[index new create]
  helper_method :empty_task_status

  def index
    @image_projects = ImageProject.order(updated_at: :desc)
  end

  def new
    @image_project = ImageProject.new(name: "Product Detail Image Project")
  end

  def create
    @image_project = ImageProject.new(image_project_params)

    if @image_project.save
      redirect_to @image_project
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    load_editor_state
  end

  def destroy
    project_name = @image_project.name
    ImageProjects::ProjectDestroyer.call(@image_project)

    redirect_to image_projects_path, notice: "Project \"#{project_name}\" deleted."
  rescue StandardError => error
    redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: "Project delete failed: #{error.message}"
  end

  def update
    if params.key?(:config_json_text)
      save_raw_config
    else
      save_editor_config
    end

    redirect_to image_project_path(@image_project, task_index: selected_task_index), notice: "Configuration saved."
  rescue JSON::ParserError => error
    redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: "Invalid JSON: #{error.message}"
  end

  def upload_images
    ensure_alias_column!(ImageAsset)
    result = upload_assets(:images, ImageAsset::SUPPORTED_EXTENSIONS) do |uploaded|
      size = image_dimensions_for(uploaded)
      asset = @image_project.image_assets.create!(
        name: uploaded.original_filename,
        alias_name: ImageProjects::AssetNameNormalizer.default_alias(uploaded.original_filename),
        normalized_name: ImageProjects::AssetNameNormalizer.extensionless(uploaded.original_filename),
        width: size&.first,
        height: size&.last
      )
      attach_uploaded_file(asset.file, uploaded)
    end

    redirect_to image_project_path(@image_project, task_index: selected_task_index), notice: upload_notice("image", result)
  rescue StandardError => error
    redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: "Image upload failed: #{upload_failure_message(error, ImageAsset)}"
  end

  def upload_fonts
    ensure_alias_column!(FontAsset)
    result = upload_assets(:fonts, FontAsset::SUPPORTED_EXTENSIONS) do |uploaded|
      asset = @image_project.font_assets.create!(
        name: uploaded.original_filename,
        alias_name: ImageProjects::AssetNameNormalizer.default_alias(uploaded.original_filename),
        normalized_name: ImageProjects::AssetNameNormalizer.extensionless(uploaded.original_filename)
      )
      attach_uploaded_file(asset.file, uploaded)
    end

    redirect_to image_project_path(@image_project, task_index: selected_task_index), notice: upload_notice("font", result)
  rescue StandardError => error
    redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: "Font upload failed: #{upload_failure_message(error, FontAsset)}"
  end

  def import_excel
    uploaded = params[:excel_file]
    raise "Choose an Excel file to import." if uploaded.blank?

    ImageProjects::ExcelImporter.call(@image_project, uploaded.tempfile)
    redirect_to @image_project, notice: "Excel file imported into JSON configuration."
  rescue StandardError => error
    redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: "Excel import failed: #{error.message}"
  end

  def preview
    index = selected_task_index
    task = @image_project.tasks[index]
    raise "No task exists at index #{index}." if task.blank?

    result = ImageProjects::Renderer.new(@image_project).render_preview(task, scale: 0.5)
    if result.path.present? && File.exist?(result.path)
      begin
        File.open(result.path, "rb") do |file|
          @image_project.preview_file.attach(
            io: file,
            filename: "preview-#{result.filename}",
            content_type: mime_type(result.format)
          )
        end
        @image_project.update!(
          preview_task_index: index,
          preview_task_name: task_display_name(task, index)
        )
      ensure
        ImageProjects::TempfileManager.delete(result.path)
      end
    end

    flash_message = []
    flash_message << "Warnings: #{result.warnings.join(" | ")}" if result.warnings.any?
    flash_message << "Errors: #{result.errors.join(" | ")}" if result.errors.any?
    redirect_to image_project_path(@image_project, task_index: index),
                notice: flash_message.presence&.join(" ") || "Preview generated."
  rescue StandardError => error
    redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: "Preview failed: #{error.message}"
  end

  def generate
    job = ImageProjects::GenerationRunner.call(@image_project)
    redirect_to image_project_path(@image_project, task_index: selected_task_index),
                notice: "Generation #{job.status}. #{job.generated_images.count} image records created."
  rescue StandardError => error
    redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: "Generation failed: #{error.message}"
  end

  def generate_current
    index = selected_task_index
    task = @image_project.tasks[index]
    raise "No task exists at index #{index}." if task.blank?

    job = ImageProjects::GenerationRunner.call(@image_project, task_indexes: [ index ])
    redirect_to image_project_path(@image_project, task_index: index),
                notice: "Current task generation #{job.status}. #{job.generated_images.count} image record created."
  rescue StandardError => error
    redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: "Current task generation failed: #{error.message}"
  end

  def download_zip
    job = @image_project.latest_generation_job
    raise "No generated ZIP is available yet." unless job&.zip_file&.attached?

    send_data attachment_bytes(job.zip_file),
              filename: job.zip_file.filename.to_s,
              type: "application/zip",
              disposition: "attachment"
  rescue StandardError => error
    redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: error.message
  end

  def add_task
    config = @image_project.config_hash
    config["tasks"] ||= []
    config["tasks"] << new_task("Task #{config["tasks"].size + 1}")
    @image_project.update_config!(config)
    redirect_to image_project_path(@image_project, task_index: config["tasks"].size - 1)
  end

  def duplicate_task
    config = @image_project.config_hash
    tasks = config["tasks"] ||= []
    task = tasks[selected_task_index]&.deep_dup
    tasks.insert(selected_task_index + 1, duplicate_task_config(task)) if task
    @image_project.update_config!(config)
    redirect_to image_project_path(@image_project, task_index: selected_task_index + 1)
  end

  def delete_task
    config = @image_project.config_hash
    tasks = config["tasks"] ||= []
    tasks.delete_at(selected_task_index)
    tasks << new_task("Task 1") if tasks.empty?
    @image_project.update_config!(config)
    redirect_to image_project_path(@image_project, task_index: [ selected_task_index, tasks.size - 1 ].min)
  end

  def move_task
    config = @image_project.config_hash
    tasks = config["tasks"] ||= []
    new_index = move_item(tasks, selected_task_index, params[:direction])
    @image_project.update_config!(config)
    redirect_to image_project_path(@image_project, task_index: new_index)
  end

  def add_layer
    config = @image_project.config_hash
    task = task_at(config, selected_task_index)
    task["layers"] ||= []
    task["layers"] << new_layer(params[:layer_type], task["layers"].size)
    @image_project.update_config!(config)
    redirect_to image_project_path(@image_project, task_index: selected_task_index)
  end

  def duplicate_layer
    config = @image_project.config_hash
    task = task_at(config, selected_task_index)
    layers = task["layers"] ||= []
    layer = layers[layer_index]&.deep_dup
    if layer
      layer["id"] = "layer#{layers.size}"
      layer["name"] = "#{layer["name"]} Copy"
      layers.insert(layer_index + 1, layer)
    end
    @image_project.update_config!(config)
    redirect_to image_project_path(@image_project, task_index: selected_task_index)
  end

  def delete_layer
    config = @image_project.config_hash
    task = task_at(config, selected_task_index)
    task.fetch("layers", []).delete_at(layer_index)
    @image_project.update_config!(config)
    redirect_to image_project_path(@image_project, task_index: selected_task_index)
  end

  def move_layer
    config = @image_project.config_hash
    task = task_at(config, selected_task_index)
    move_item(task["layers"] ||= [], layer_index, params[:direction])
    @image_project.update_config!(config)
    redirect_to image_project_path(@image_project, task_index: selected_task_index)
  end

  def destroy_image_asset
    @image_project.image_assets.find(params[:asset_id]).destroy
    redirect_to image_project_path(@image_project, task_index: selected_task_index), notice: "Image deleted."
  end

  def update_image_asset
    ensure_alias_column!(ImageAsset)
    asset = @image_project.image_assets.find(params[:asset_id])

    if asset.update(alias_name: params.dig(:image_asset, :alias_name))
      redirect_to image_project_path(@image_project, task_index: selected_task_index), notice: "Image alias updated."
    else
      redirect_to image_project_path(@image_project, task_index: selected_task_index),
                  alert: "Image alias could not be updated: #{asset.errors.full_messages.to_sentence}"
    end
  end

  def destroy_font_asset
    @image_project.font_assets.find(params[:asset_id]).destroy
    redirect_to image_project_path(@image_project, task_index: selected_task_index), notice: "Font deleted."
  end

  def update_font_asset
    ensure_alias_column!(FontAsset)
    asset = @image_project.font_assets.find(params[:asset_id])

    if asset.update(alias_name: params.dig(:font_asset, :alias_name))
      redirect_to image_project_path(@image_project, task_index: selected_task_index), notice: "Font alias updated."
    else
      redirect_to image_project_path(@image_project, task_index: selected_task_index),
                  alert: "Font alias could not be updated: #{asset.errors.full_messages.to_sentence}"
    end
  end

  private

  def set_image_project
    @image_project = ImageProject.find(params[:id])
  end

  def image_project_params
    params.require(:image_project).permit(:name)
  end

  def ensure_alias_column!(model_class)
    return if model_class.column_names.include?("alias_name")

    model_class.reset_column_information
    return if model_class.column_names.include?("alias_name")

    raise missing_alias_column_message(model_class)
  end

  def upload_failure_message(error, model_class)
    return missing_alias_column_message(model_class) if alias_column_error?(error)

    error.message
  end

  def alias_column_error?(error)
    message = error.message.to_s
    unknown_attribute = error.is_a?(ActiveModel::UnknownAttributeError) && message.include?("alias_name")
    missing_column = message.match?(/alias_name/i) && message.match?(/unknown attribute|no column|has no column|missing/i)

    unknown_attribute || missing_column
  end

  def missing_alias_column_message(model_class)
    "Database is missing #{model_class.table_name}.alias_name. Please run bundle exec rails db:migrate and restart the Rails server."
  end

  def load_editor_state
    @config = @image_project.config_hash
    @tasks = @config.fetch("tasks", [])
    @selected_task_index = selected_task_index
    @task = @tasks[@selected_task_index] || new_task("Task 1")
    @latest_job = @image_project.latest_generation_job
    @task_statuses = task_statuses_for(@tasks, @latest_job)
    @selected_task_status = @task_statuses[@selected_task_index] || empty_task_status(@task)
    @selected_task_name = @selected_task_status[:target_name]
    @preview_matches_selected_task = preview_belongs_to_task?(@selected_task_index, @selected_task_name)
    @readiness_summary = readiness_summary_for(@tasks)
  end

  def save_raw_config
    parsed = JSON.parse(params[:config_json_text])
    @image_project.update!(
      name: params.dig(:image_project, :name).presence || @image_project.name,
      config_json: JSON.pretty_generate(parsed),
      last_error: nil
    )
  end

  def save_editor_config
    config = @image_project.config_hash
    config["projectName"] = params.dig(:image_project, :name).presence || @image_project.name
    config["tasks"] ||= []
    task = task_from_params(config["tasks"][selected_task_index] || new_task("Task #{selected_task_index + 1}"))
    config["layoutMode"] = task["layoutMode"] if task["layoutMode"].present?
    config["tasks"][selected_task_index] = task
    apply_editor_operation!(config)

    @image_project.update!(
      name: params.dig(:image_project, :name).presence || @image_project.name,
      config_json: JSON.pretty_generate(config),
      last_error: nil
    )
  end

  def task_from_params(existing_task)
    task_params = params.fetch(:task, {}).permit!.to_h
    layer_params = params.fetch(:layers, {}).permit!.to_h.values
    task = existing_task.deep_dup
    task["targetName"] = task_params["targetName"].presence || task["targetName"].presence || "Task #{selected_task_index + 1}"
    task["layoutMode"] = normalize_layout_mode(task_params["layoutMode"].presence || task["layoutMode"] || "strict")
    task["canvas"] = {
      "width" => integer_param(task_params.dig("canvas", "width"), task.dig("canvas", "width") || 1650),
      "height" => integer_param(task_params.dig("canvas", "height"), task.dig("canvas", "height") || 2480),
      "backgroundColor" => task_params.dig("canvas", "backgroundColor").presence || task.dig("canvas", "backgroundColor") || "#FAFAF0",
      "transparent" => truthy_param?(task_params.dig("canvas", "transparent"))
    }
    task["output"] = {
      "width" => integer_param(task_params.dig("output", "width"), task.dig("output", "width") || task.dig("canvas", "width") || 1650),
      "height" => integer_param(task_params.dig("output", "height"), task.dig("output", "height") || task.dig("canvas", "height") || 2480),
      "format" => normalize_output_format(task_params.dig("output", "format"))
    }
    existing_layers = Array(existing_task["layers"])
    task["layers"] = layer_params.each_with_index.map { |layer, index| layer_from_params(layer, index, existing_layers[index]) }
    apply_editor_text_defaults!(task)
    task
  end

  def layer_from_params(layer, index, existing_layer = nil)
    type = layer["type"].presence || "text"
    common = (existing_layer || {}).deep_dup.merge(
      "id" => layer["id"].presence || "layer#{index}",
      "name" => layer["name"].presence || "Layer #{index + 1}",
      "type" => type,
      "x" => scalar_position(layer["x"]),
      "y" => scalar_position(layer["y"]),
      "opacity" => decimal_param(layer["opacity"], 1)
    )

    if type == "image"
      common.merge(
        "imageName" => layer["imageName"].to_s.strip,
        "width" => integer_param(layer["width"], 100),
        "height" => integer_param(layer["height"], 100),
        "fit" => %w[contain cover stretch].include?(layer["fit"].to_s) ? layer["fit"] : "contain"
      )
    else
      letter_spacing_mode = normalize_letter_spacing_mode(layer["letterSpacingMode"].presence || existing_layer&.dig("letterSpacingMode"))
      result = common.merge(
        "text" => layer["text"].to_s,
        "font" => layer["font"].to_s.strip,
        "fontSize" => integer_param(layer["fontSize"], 60),
        "color" => layer["color"].presence,
        "letterSpacingRatio" => decimal_param(layer["letterSpacingRatio"], 0),
        "lineHeightRatio" => decimal_param(layer["lineHeightRatio"], 1.2),
        "maxWidth" => integer_param(layer["maxWidth"], nil),
        "autoWrap" => truthy_param?(layer["autoWrap"]),
        "bold" => truthy_param?(layer["bold"]),
        "italic" => truthy_param?(layer["italic"]),
        "align" => %w[left center right].include?(layer["align"].to_s) ? layer["align"] : "center",
        "notes" => layer["notes"].to_s
      ).compact
      if letter_spacing_mode == "spread"
        result["letterSpacingMode"] = "spread"
        result["targetTextWidthRatio"] = decimal_param(layer["targetTextWidthRatio"], existing_layer&.dig("targetTextWidthRatio") || 0.78)
      else
        result.delete("letterSpacingMode")
        result.delete("targetTextWidthRatio")
      end
      result
    end
  end

  def apply_editor_text_defaults!(task)
    default_color = default_text_color_for_task(task)
    Array(task["layers"]).each do |layer|
      next unless layer["type"].to_s == "text"

      layer["color"] = default_color if layer["color"].blank?
    end
  end

  def default_text_color_for_task(task)
    canvas = task.fetch("canvas", {})
    background = canvas["backgroundColor"].to_s.downcase
    return "#F4EAD7" if truthy_param?(canvas["transparent"]) || background == "transparent" || editor_full_image_background?(task)

    "#1F1F1F"
  end

  def editor_full_image_background?(task)
    canvas_width = task.dig("canvas", "width").to_i
    canvas_height = task.dig("canvas", "height").to_i
    return false if canvas_width <= 0 || canvas_height <= 0

    Array(task["layers"]).any? do |layer|
      layer["type"].to_s == "image" &&
        layer["width"].to_i >= (canvas_width * 0.95) &&
        layer["height"].to_i >= (canvas_height * 0.95)
    end
  end

  def upload_assets(param_name, extensions)
    files = uploaded_files_for(param_name)

    raise "Choose one or more files to upload." if files.empty?

    uploaded_count = 0
    skipped_files = []

    files.each do |uploaded|
      filename = uploaded.original_filename.to_s
      extension = File.extname(filename).downcase

      unless extensions.include?(extension)
        skipped_files << filename
        next
      end

      yield uploaded
      uploaded_count += 1
    end

    {
      uploaded_count: uploaded_count,
      skipped_files: skipped_files
    }
  end

  def image_dimensions_for(uploaded)
    File.open(uploaded.tempfile.path, "rb") do |file|
      FastImage.size(file)
    end
  end

  def attach_uploaded_file(attachment, uploaded)
    File.open(uploaded.tempfile.path, "rb") do |file|
      attachment.attach(
        io: file,
        filename: uploaded.original_filename,
        content_type: uploaded.content_type
      )
    end
  end

  def attachment_bytes(attachment)
    bytes = +"".b
    attachment.blob.download { |chunk| bytes << chunk }
    bytes
  end

  def uploaded_files_for(param_name)
    raw = params[param_name]
    return [] if raw.blank?

    files =
      case raw
      when ActionDispatch::Http::UploadedFile
        [ raw ]
      when Array
        raw
      when ActionController::Parameters
        raw.to_unsafe_h.values
      when Hash
        raw.values
      else
        [ raw ]
      end

    files.flatten.compact.select do |file|
      file.respond_to?(:original_filename) &&
        file.respond_to?(:tempfile) &&
        file.original_filename.present?
    end
  end

  def upload_notice(asset_type, result)
    label = asset_type == "font" ? "font" : "image"
    notice = "#{result[:uploaded_count]} #{label}(s) uploaded."
    notice += " Skipped unsupported files: #{result[:skipped_files].join(', ')}" if result[:skipped_files].any?
    notice
  end

  def apply_editor_operation!(config)
    operation = params[:editor_operation].to_s
    return if operation.blank?

    task = task_at(config, selected_task_index)
    layers = task["layers"] ||= []

    case operation
    when "add_image_layer"
      layers << new_layer("image", layers.size)
    when "add_text_layer"
      layers << new_layer("text", layers.size)
    when /\Adelete_layer:(\d+)\z/
      layers.delete_at(Regexp.last_match(1).to_i)
    when /\Aduplicate_layer:(\d+)\z/
      index = Regexp.last_match(1).to_i
      layer = layers[index]&.deep_dup
      if layer
        layer["id"] = "layer#{layers.size}"
        layer["name"] = "#{layer["name"]} Copy"
        layers.insert(index + 1, layer)
      end
    when /\Amove_layer:(\d+):(up|down)\z/
      move_item(layers, Regexp.last_match(1).to_i, Regexp.last_match(2))
    end
  end

  def task_statuses_for(tasks, latest_job)
    image_matcher = ImageProjects::ImageMatcher.new(@image_project)
    font_matcher = ImageProjects::FontMatcher.new(@image_project)
    latest_generated = latest_generated_by_target(latest_job)

    tasks.map do |task|
      target_name = task["targetName"].presence || "Untitled task"
      warnings = Array(task["warnings"]).dup
      errors = []
      missing_image = false
      missing_font = false

      Array(task["layers"]).each do |layer|
        case layer["type"].to_s
        when "image"
          image_name = layer["imageName"].to_s.strip
          next if image_name.blank?

          match = image_matcher.match(image_name)
          if match.found?
            warnings << match.warning if match.warning.present?
            next
          end

          missing_image = true
          errors << "Task #{target_name} could not be generated because source image \"#{image_name}\" was not found."
        when "text"
          font_name = layer["font"].to_s.strip
          next if font_name.blank?

          match = font_matcher.match(font_name)
          next unless match.fallback?

          missing_font = true
          warnings << match.warning
        end
      end

      generated = latest_generated[target_name]
      if generated
        warnings.concat(generated.warnings_list)
        errors.concat(generated.errors_list)
      end

      status_key = task_status_key(generated, missing_image, missing_font, errors)
      {
        target_name: target_name,
        status: status_key,
        label: task_status_label(status_key),
        warnings: warnings.compact_blank.uniq,
        errors: errors.compact_blank.uniq,
        layer_count: Array(task["layers"]).size
      }
    end
  end

  def readiness_summary_for(tasks)
    image_matcher = ImageProjects::ImageMatcher.new(@image_project)
    font_matcher = ImageProjects::FontMatcher.new(@image_project)

    {
      tasks: tasks.map { |task| task["targetName"].presence || "Untitled task" },
      images: required_image_names(tasks).map { |name| readiness_image(name, image_matcher) },
      fonts: required_font_names(tasks).map { |name| readiness_font(name, font_matcher) }
    }
  end

  def readiness_image(name, matcher)
    match = matcher.match(name)
    if match.found?
      { name: name, status: "matched", message: "#{name} matched to #{match.asset.name}" }
    else
      { name: name, status: "missing", message: "#{name} missing" }
    end
  end

  def readiness_font(name, matcher)
    match = matcher.match(name)
    if match.found?
      { name: name, status: "matched", message: "#{name} matched to #{match.asset.name}" }
    else
      { name: name, status: "warning", message: missing_font_message(name) }
    end
  end

  def required_image_names(tasks)
    unique_layer_values(tasks, "image", "imageName")
  end

  def required_font_names(tasks)
    unique_layer_values(tasks, "text", "font")
  end

  def unique_layer_values(tasks, type, key)
    seen = {}
    tasks.flat_map { |task| Array(task["layers"]) }
      .select { |layer| layer["type"].to_s == type }
      .filter_map { |layer| layer[key].to_s.strip.presence }
      .each_with_object([]) do |value, values|
        normalized = ImageProjects::AssetNameNormalizer.full(value)
        next if seen[normalized]

        seen[normalized] = true
        values << value
      end
  end

  def latest_generated_by_target(latest_job)
    return {} unless latest_job

    latest_job.generated_images.includes(file_attachment: :blob).index_by(&:target_name)
  end

  def task_status_key(generated, missing_image, missing_font, errors)
    return "failed" if generated&.errors_list&.any?
    return "generated" if generated&.file&.attached?
    return "missing_image" if missing_image || errors.any?
    return "missing_font" if missing_font

    "ready"
  end

  def task_status_label(status)
    {
      "ready" => "ready",
      "missing_image" => "missing image",
      "missing_font" => "missing font",
      "generated" => "generated",
      "failed" => "failed"
    }.fetch(status, "ready")
  end

  def empty_task_status(task)
    {
      target_name: task["targetName"].presence || "Task 1",
      status: "ready",
      label: "ready",
      warnings: [],
      errors: [],
      layer_count: Array(task["layers"]).size
    }
  end

  def selected_task_index
    raw = raw_selected_task_index
    tasks = Array(@image_project&.tasks)
    return 0 if tasks.empty?

    raw.clamp(0, tasks.size - 1)
  end

  def raw_selected_task_index
    return params[:task_index].presence.to_i if params[:task_index].present?
    return params[:task].presence.to_i if params[:task].is_a?(String)

    0
  end

  def task_display_name(task, index)
    task["targetName"].presence || "Task #{index + 1}"
  end

  def preview_belongs_to_task?(index, task_name)
    @image_project.preview_file.attached? &&
      @image_project.preview_task_index == index &&
      @image_project.preview_task_name.to_s == task_name.to_s
  end

  def layer_index
    params[:layer].presence.to_i
  end

  def task_at(config, index)
    config["tasks"] ||= []
    config["tasks"][index] ||= new_task("Task #{index + 1}")
  end

  def new_task(name)
    {
      "targetName" => name,
      "layoutMode" => "strict",
      "canvas" => {
        "width" => 1650,
        "height" => 2480,
        "backgroundColor" => "#FAFAF0",
        "transparent" => false
      },
      "output" => {
        "width" => 1650,
        "height" => 2480,
        "format" => "jpg"
      },
      "layers" => []
    }
  end

  def duplicate_task_config(task)
    return nil unless task

    copy = task.deep_dup
    copy["targetName"] = "#{copy["targetName"].presence || "Task"} Copy"
    copy
  end

  def new_layer(type, index)
    if type.to_s == "image"
      {
        "id" => "layer#{index}",
        "name" => "Image Layer",
        "type" => "image",
        "imageName" => "",
        "width" => 800,
        "height" => 800,
        "x" => "center",
        "y" => 0,
        "fit" => "contain",
        "opacity" => 1
      }
    else
      {
        "id" => "layer#{index}",
        "name" => "Text Layer",
        "type" => "text",
        "text" => "",
        "font" => "",
        "fontSize" => 60,
        "color" => "#1F1F1F",
        "letterSpacingRatio" => 0,
        "lineHeightRatio" => 1.2,
        "maxWidth" => 1200,
        "autoWrap" => true,
        "bold" => false,
        "italic" => false,
        "x" => "center",
        "y" => 200,
        "align" => "center",
        "opacity" => 1
      }
    end
  end

  def move_item(items, index, direction)
    return index unless items[index]

    new_index = direction == "up" ? index - 1 : index + 1
    return index if new_index.negative? || new_index >= items.size

    items[index], items[new_index] = items[new_index], items[index]
    new_index
  end

  def integer_param(value, fallback)
    return fallback if value.blank?

    value.to_i
  end

  def decimal_param(value, fallback)
    return fallback if value.blank?

    value.to_f
  end

  def scalar_position(value)
    text = value.to_s.strip
    return "center" if text.downcase == "center"
    return 0 if text.blank?

    text.match?(/\A-?\d+(?:\.\d+)?\z/) ? text.to_f : text
  end

  def truthy_param?(value)
    value == true || value.to_s == "1" || value.to_s == "true"
  end

  def normalize_output_format(format)
    normalized = format.to_s.downcase
    return "png" if normalized == "png"
    return "webp" if normalized == "webp"

    "jpg"
  end

  def normalize_layout_mode(value)
    value.to_s == "design" ? "design" : "strict"
  end

  def normalize_letter_spacing_mode(value)
    value.to_s == "spread" ? "spread" : nil
  end

  def missing_font_message(name)
    "Font \"#{name}\" was not uploaded. A fallback font was used, so the generated image may not visually match the expected design."
  end

  def mime_type(format)
    case format
    when "png"
      "image/png"
    when "webp"
      "image/webp"
    else
      "image/jpeg"
    end
  end
end
