class ImageProjectsController < ApplicationController
  before_action :set_image_project, except: %i[index new create]
  helper_method :empty_task_status, :font_options_for

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

  def delete_confirmation
    @delete_summary = project_delete_summary
    @cancel_delete_path = delete_cancel_path
  end

  def clear_data_confirmation
    @clear_summary = project_data_clear_summary
    @cancel_clear_path = clear_cancel_path
  end

  def destroy
    unless delete_confirmation_matches?
      @delete_summary = project_delete_summary
      @cancel_delete_path = delete_cancel_path
      flash.now[:alert] = "Type the project name exactly to confirm deletion."
      render :delete_confirmation, status: :unprocessable_entity
      return
    end

    project_name = @image_project.name
    ImageProjects::ProjectDestroyer.call(@image_project)

    redirect_to image_projects_path, notice: "Project \"#{project_name}\" deleted."
  rescue StandardError => error
    destination = @image_project.persisted? ? delete_confirmation_image_project_path(@image_project) : image_projects_path
    redirect_to destination, alert: "Project delete failed: #{error.message}"
  end

  def clear_project_data
    unless clear_confirmation_matches?
      @clear_summary = project_data_clear_summary
      @cancel_clear_path = clear_cancel_path
      flash.now[:alert] = "Type CLEAR to confirm clearing project data."
      render :clear_data_confirmation, status: :unprocessable_entity
      return
    end

    ImageProjects::ProjectDataResetter.call(@image_project)

    redirect_to image_project_path(@image_project), notice: "Project data cleared. Font Library was kept."
  rescue StandardError => error
    redirect_to clear_data_confirmation_image_project_path(@image_project), alert: "Clear project data failed: #{error.message}"
  end

  def update
    saved = false

    if params.key?(:config_json_text)
      save_raw_config
    else
      save_editor_config
    end
    saved = true
    @image_project.reload

    respond_after_editor_save
  rescue JSON::ParserError => error
    respond_to_action_error(error, fallback_prefix: "Invalid JSON")
  rescue StandardError => error
    alert = saved ? "#{after_save_failure_prefix}: #{error.message}" : "Configuration save failed: #{error.message}"
    respond_to_action_error(error, fallback_prefix: alert, include_error_message: false)
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

  def upload_global_fonts
    result = upload_assets(:fonts, GlobalFontAsset::SUPPORTED_EXTENSIONS) do |uploaded, upload_count|
      asset = GlobalFontAsset.create!(
        name: uploaded.original_filename,
        match_name: global_font_upload_match_name(upload_count, uploaded.original_filename),
        normalized_name: ImageProjects::AssetNameNormalizer.extensionless(uploaded.original_filename)
      )
      attach_uploaded_file(asset.file, uploaded)
    end

    redirect_to font_library_path,
                notice: "#{upload_notice("font", result)} Uploaded fonts are available in the global Font Library."
  rescue StandardError => error
    redirect_to font_library_path,
                alert: "Global font upload failed: #{upload_failure_message(error, GlobalFontAsset)}"
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
    save_request_config_if_present!
    @image_project.reload
    index = selected_task_index
    ensure_task_previewable!(index)
    result = preview_generation_for_selected_task!(index)
    respond_to_preview_start(result, task_index: index, saved: params.key?(:task) || params.key?(:layers) || params.key?(:image_project))
  rescue StandardError => error
    respond_to_action_error(error, fallback_prefix: "Preview failed")
  end

  def preview_all
    save_request_config_if_present!
    @image_project.reload
    result = preview_generation_for_all_tasks!
    respond_to_preview_all_start(result, saved: params.key?(:task) || params.key?(:layers) || params.key?(:image_project))
  rescue JSON::ParserError => error
    respond_to_action_error(error, fallback_prefix: "Invalid JSON")
  rescue StandardError => error
    respond_to_action_error(error, fallback_prefix: "Preview all failed")
  end

  def generate
    save_request_config_if_present!
    @image_project.reload
    ensure_project_downloadable!
    result = zip_generation_for_current_inputs!
    respond_to_zip_start(result, saved: params.key?(:task) || params.key?(:layers) || params.key?(:image_project))
  rescue StandardError => error
    respond_to_action_error(error, fallback_prefix: "Generation failed")
  end

  def generate_current
    index = selected_task_index
    redirect_to image_project_path(@image_project, task_index: index),
                alert: "Current-image final generation is no longer run in the request. Use Generate ZIP (All Images) to start background generation."
  rescue StandardError => error
    redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: "Current task generation failed: #{error.message}"
  end

  def download_zip
    save_request_config_if_present!
    @image_project.reload
    ensure_project_downloadable!
    input_signature = ImageProjects::RenderInputSignature.full_zip(@image_project)
    cached_job = @image_project.latest_completed_zip_job(input_signature: input_signature)

    if cached_job
      Rails.logger.info(
        "Cached ZIP reused image_project_id=#{@image_project.id} image_generation_job_id=#{cached_job.id} " \
        "signature=#{input_signature.first(12)}"
      )
      redirect_to_zip_file(cached_job)
    else
      active_job = active_zip_job_for_signature(input_signature)
      message = if active_job
                  "ZIP generation is #{active_job.status}. You can leave this page and come back later."
                else
                  "ZIP is not ready yet. Save the project and use Generate ZIP (All Images) to start background generation."
                end
      redirect_to image_project_path(@image_project, task_index: selected_task_index), notice: message
    end
  rescue StandardError => error
    redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: error.message
  end

  def generation_job_status
    job = @image_project.image_generation_jobs.find(params[:job_id])
    refresh_stale_running_job!(job)

    render json: generation_job_status_payload(job.reload)
  end

  def preview_generation_job_status
    job = @image_project.preview_generation_jobs.find(params[:job_id])
    refresh_stale_running_preview_job!(job)

    render json: preview_generation_job_status_payload(job.reload)
  end

  def download_generation_job
    job = @image_project.image_generation_jobs.find(params[:job_id])

    if job.downloadable?
      redirect_to_zip_file(job)
    else
      redirect_to image_project_path(@image_project, task_index: selected_task_index),
                  alert: "ZIP is not ready yet. Current status: #{job.status}."
    end
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

  def update_global_font_asset
    asset = GlobalFontAsset.find(params[:asset_id])

    if asset.update(match_name: params.dig(:global_font_asset, :match_name))
      redirect_to font_library_path, notice: "Font match name updated."
    else
      redirect_to font_library_path,
                  alert: "Font match name could not be updated: #{asset.errors.full_messages.to_sentence}"
    end
  end

  def destroy_global_font_asset
    asset = GlobalFontAsset.find(params[:asset_id])

    if global_font_asset_referenced?(asset)
      redirect_to font_library_path,
                  alert: "Global font \"#{asset.name}\" is used by one or more projects and was not deleted."
    else
      asset.destroy
      redirect_to font_library_path, notice: "Global font deleted."
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

  def font_library_path
    image_project_path(@image_project, task_index: selected_task_index, anchor: "font-library")
  end

  def delete_confirmation_matches?
    params[:confirm_project_name].to_s == @image_project.name.to_s
  end

  def clear_confirmation_matches?
    params[:confirm_clear].to_s == "CLEAR"
  end

  def delete_cancel_path
    path = params[:return_to].to_s
    return path if local_path?(path)

    image_project_path(@image_project)
  end

  def clear_cancel_path
    path = params[:return_to].to_s
    return path if local_path?(path)

    image_project_path(@image_project)
  end

  def local_path?(path)
    path.start_with?("/") && !path.start_with?("//")
  end

  def project_delete_summary
    {
      project_name: @image_project.name,
      status: @image_project.status,
      task_count: @image_project.tasks.size,
      image_asset_count: @image_project.image_assets.count,
      task_preview_count: @image_project.task_previews.count,
      generation_job_count: @image_project.image_generation_jobs.count,
      preview_generation_job_count: @image_project.preview_generation_jobs.count,
      zip_file_count: project_zip_file_count,
      last_updated_at: @image_project.updated_at
    }
  end

  def project_data_clear_summary
    {
      project_name: @image_project.name,
      status: @image_project.status,
      task_count: @image_project.tasks.size,
      image_asset_count: @image_project.image_assets.count,
      task_preview_count: @image_project.task_previews.count,
      preview_generation_job_count: @image_project.preview_generation_jobs.count,
      generation_job_count: @image_project.image_generation_jobs.count,
      generated_image_count: project_generated_image_count,
      zip_file_count: project_zip_file_count,
      legacy_preview_file_count: @image_project.preview_file.attached? ? 1 : 0,
      project_font_asset_count: @image_project.font_assets.count,
      global_font_asset_count: GlobalFontAsset.count,
      last_updated_at: @image_project.updated_at
    }
  end

  def project_zip_file_count
    ActiveStorage::Attachment
      .where(
        record_type: "ImageGenerationJob",
        record_id: @image_project.image_generation_jobs.select(:id),
        name: "zip_file"
      )
      .count
  end

  def project_generated_image_count
    GeneratedImage.where(image_generation_job_id: @image_project.image_generation_jobs.select(:id)).count
  end

  def load_editor_state
    @config = @image_project.config_hash
    @tasks = @config.fetch("tasks", [])
    @global_font_assets = GlobalFontAsset.order(:name).to_a
    @project_font_assets = @image_project.font_assets.order(:name).to_a
    @selected_task_index = selected_task_index
    @task = @tasks[@selected_task_index] || new_task("Task 1")
    @latest_job = @image_project.latest_generation_job
    @task_statuses = task_statuses_for(@tasks, @latest_job)
    @selected_task_status = @task_statuses[@selected_task_index] || empty_task_status(@task)
    @selected_task_name = @selected_task_status[:target_name]
    @selected_task_preview_signature = preview_signature_for_task(@selected_task_index)
    @selected_task_preview = current_task_preview_for(@selected_task_index, @selected_task_name, @selected_task_preview_signature)
    @stale_task_preview = stale_task_preview_for(@selected_task_index, @selected_task_preview)
    @preview_matches_selected_task = @selected_task_preview.present?
    @readiness_summary = readiness_summary_for(@tasks)
    @selected_task_preview_readiness = task_preview_readiness(@task)
    @selected_task_previewable = @selected_task_preview_readiness[:ready]
    @project_preview_all_readiness = project_preview_all_readiness(@tasks)
    @project_preview_all_available = @project_preview_all_readiness[:ready]
    @project_download_readiness = project_download_readiness(@tasks)
    @project_downloadable = @project_download_readiness[:ready]
    load_zip_generation_state
    load_preview_generation_state
  end

  def respond_after_editor_save
    case params[:after_save_action].to_s
    when "preview_current"
      index = selected_task_index
      ensure_task_previewable!(index)
      result = preview_generation_for_selected_task!(index)
      respond_to_preview_start(result, task_index: index, saved: true)
    when "preview_all"
      result = preview_generation_for_all_tasks!
      respond_to_preview_all_start(result, saved: true)
    when "download_zip"
      ensure_project_downloadable!
      result = zip_generation_for_current_inputs!
      respond_to_zip_start(result, saved: true)
    when "generate_current"
      index = selected_task_index
      redirect_to image_project_path(@image_project, task_index: index),
                  alert: "Configuration saved. Current-image final generation is no longer run in the request. Use Generate ZIP (All Images) to start background generation."
    when "generate_all"
      ensure_project_downloadable!
      result = zip_generation_for_current_inputs!
      respond_to_zip_start(result, saved: true)
    else
      redirect_to image_project_path(@image_project, task_index: selected_task_index), notice: "Configuration saved."
    end
  end

  def after_save_failure_prefix
    case params[:after_save_action].to_s
    when "preview_current"
      "Configuration saved, but preview failed"
    when "preview_all"
      "Configuration saved, but preview all failed"
    when "download_zip"
      "Configuration saved, but ZIP generation failed"
    when "generate_current"
      "Configuration saved, but current task generation failed"
    when "generate_all"
      "Configuration saved, but generation failed"
    else
      "Configuration save failed"
    end
  end

  def preview_generation_for_selected_task!(index)
    ImageProjects::PreviewGenerationRunner.prepare_selected(@image_project, task_index: index)
  end

  def preview_generation_for_all_tasks!
    ImageProjects::PreviewGenerationRunner.prepare_all(@image_project)
  end

  def respond_to_preview_start(result, task_index:, saved: false)
    if json_request?
      render json: preview_start_payload(result, saved: saved), status: :ok
    else
      redirect_to image_project_path(@image_project, task_index: task_index),
                  notice: prefixed_action_message(result[:message], saved: saved)
    end
  end

  def respond_to_preview_all_start(result, saved: false)
    status = result[:state] == :no_previewable ? :unprocessable_entity : :ok
    if json_request?
      render json: preview_all_start_payload(result, saved: saved), status: status
    else
      flash_key = result[:state] == :no_previewable ? :alert : :notice
      redirect_to image_project_path(@image_project, task_index: selected_task_index),
                  flash_key => prefixed_action_message(result[:message], saved: saved)
    end
  end

  def respond_to_zip_start(result, saved: false)
    if json_request?
      render json: zip_generation_start_payload(result, saved: saved), status: :ok
    elsif result[:state] == :cached
      flash[:notice] = prefixed_action_message("Reused cached ZIP.", saved: saved)
      redirect_to_zip_file(result[:job])
    else
      redirect_to image_project_path(@image_project, task_index: selected_task_index),
                  notice: prefixed_action_message(zip_generation_notice(result), saved: saved)
    end
  end

  def respond_to_action_error(error, fallback_prefix:, include_error_message: true)
    message = include_error_message ? "#{fallback_prefix}: #{error.message}" : fallback_prefix
    if json_request?
      render json: { state: "failed_validation", message: message, errors: [ error.message ] }, status: :unprocessable_entity
    else
      redirect_to image_project_path(@image_project, task_index: selected_task_index), alert: message
    end
  end

  def preview_start_payload(result, saved: false)
    preview = result[:preview]
    job = result[:job]
    {
      state: result[:state].to_s,
      status: job&.status || "completed",
      scope: job&.scope || PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE,
      job_id: job&.id,
      task_indexes: [ result[:task_index] ].compact,
      input_signature: result[:input_signature],
      status_url: (preview_generation_job_status_image_project_path(@image_project, job_id: job.id, task_index: result[:task_index]) if job),
      total_count: job&.total_count || 1,
      previewable_count: job&.previewable_count || 1,
      generated_count: job&.generated_count.to_i,
      reused_count: job&.reused_count.to_i,
      skipped_count: job&.skipped_count.to_i,
      failed_count: job&.failed_count.to_i,
      preview_url: (rails_blob_path(preview.file, only_path: true) if preview&.file&.attached?),
      downloadable: false,
      message: prefixed_action_message(result[:message], saved: saved)
    }.compact
  end

  def preview_all_start_payload(result, saved: false)
    job = result[:job]
    {
      state: result[:state].to_s,
      status: job&.status || (result[:state] == :cached ? "completed" : result[:state].to_s),
      scope: PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE,
      job_id: job&.id,
      task_indexes: job&.task_indexes || [],
      input_signature: result[:input_signature] || job&.input_signature,
      status_url: (preview_generation_job_status_image_project_path(@image_project, job_id: job.id, task_index: selected_task_index) if job),
      total_count: result[:total_count].to_i,
      previewable_count: result[:previewable_count].to_i,
      generated_count: result[:generated_count].to_i,
      reused_count: result[:reused_count].to_i,
      skipped_count: result[:skipped_count].to_i,
      failed_count: result[:failed_count].to_i,
      message: prefixed_action_message(result[:message], saved: saved)
    }.compact
  end

  def zip_generation_start_payload(result, saved: false)
    job = result[:job]
    {
      state: result[:state].to_s,
      status: job.status,
      job_id: job.id,
      generation_scope: job.generation_scope,
      input_signature: result[:input_signature],
      status_url: generation_job_status_image_project_path(@image_project, job_id: job.id),
      generated_image_count: job.generated_images.count,
      total_task_count: zip_total_task_count(job),
      downloadable: job.downloadable?,
      download_url: (generation_job_download_image_project_path(@image_project, job_id: job.id) if job.downloadable?),
      message: prefixed_action_message(result[:state] == :cached ? "Reused cached ZIP." : zip_generation_notice(result), saved: saved)
    }.compact
  end

  def prefixed_action_message(message, saved:)
    saved ? "Configuration saved. #{message}" : message
  end

  def json_request?
    request.format.json? || request.get_header("HTTP_ACCEPT").to_s.include?("application/json")
  end

  def zip_generation_for_current_inputs!
    input_signature = ImageProjects::RenderInputSignature.full_zip(@image_project)
    result = nil

    @image_project.with_lock do
      cached_job = @image_project.latest_completed_zip_job(input_signature: input_signature)
      if cached_job
        Rails.logger.info(
          "Cached ZIP reused image_project_id=#{@image_project.id} image_generation_job_id=#{cached_job.id} " \
          "signature=#{input_signature.first(12)}"
        )
        result = { job: cached_job, state: :cached, enqueued: false, input_signature: input_signature }
      else
        active_job = active_zip_job_for_signature(input_signature)
        if active_job
          Rails.logger.info(
            "Existing ZIP generation job reused image_project_id=#{@image_project.id} " \
            "image_generation_job_id=#{active_job.id} status=#{active_job.status} signature=#{input_signature.first(12)}"
          )
          result = { job: active_job, state: active_job.status.to_sym, enqueued: false, input_signature: input_signature }
        else
          queued_job = @image_project.image_generation_jobs.create!(
            generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
            input_signature: input_signature,
            status: "queued"
          )
          result = { job: queued_job, state: :queued, enqueued: true, input_signature: input_signature }
        end
      end
    end

    enqueue_zip_generation!(result[:job], input_signature) if result[:enqueued]
    result
  end

  def generation_notice(job)
    "ZIP generated. #{job.generated_images.count} image records created. Status: #{job.status}."
  end

  def current_generation_notice(job)
    "Current task generation #{job.status}. #{job.generated_images.count} image record created."
  end

  def zip_generation_notice(result)
    case result[:state]
    when :queued
      "ZIP generation started. You can leave this page and come back later."
    when :running
      "ZIP generation is already running. You can leave this page and come back later."
    else
      "ZIP generation is #{result[:job].status}. You can leave this page and come back later."
    end
  end

  def enqueue_zip_generation!(job, input_signature)
    queued = ImageProjects::GenerateZipJob.perform_later(job.id)
    raise "ZIP generation could not be queued." unless queued

    Rails.logger.info(
      "New ZIP generation job queued image_project_id=#{@image_project.id} image_generation_job_id=#{job.id} " \
      "active_job_id=#{queued.job_id} queue=#{queued.queue_name} signature=#{input_signature.first(12)}"
    )
  rescue StandardError => error
    job.update!(
      status: "failed",
      finished_at: Time.current,
      errors_list: [ "Queue enqueue failed: #{error.message}" ]
    )
    Rails.logger.error(
      "New ZIP generation job enqueue failed image_project_id=#{@image_project.id} " \
      "image_generation_job_id=#{job.id} signature=#{input_signature.first(12)} error=#{error.class}: #{error.message}"
    )
    raise
  end

  def active_zip_job_for_signature(input_signature)
    job = @image_project.latest_active_zip_job(input_signature: input_signature)
    return unless job
    return job unless refresh_stale_running_job!(job)

    nil
  end

  def refresh_stale_running_job!(job)
    return false unless job&.stale_running?

    job.update!(
      status: "failed",
      finished_at: Time.current,
      errors_list: Array(job.errors_list) + [ "ZIP generation was marked failed because it stopped updating for more than #{ImageGenerationJob::STALE_RUNNING_AFTER.inspect}." ]
    )
    Rails.logger.warn(
      "Stale ZIP generation job marked failed image_project_id=#{@image_project.id} " \
      "image_generation_job_id=#{job.id} signature=#{job.input_signature.to_s.first(12)}"
    )
    true
  end

  def redirect_to_zip_file(job)
    raise "ZIP generation did not produce a downloadable file." unless job&.zip_file&.attached?

    redirect_to rails_blob_path(job.zip_file, disposition: "attachment")
  end

  def load_zip_generation_state
    @current_zip_signature = @project_downloadable ? ImageProjects::RenderInputSignature.full_zip(@image_project) : nil
    @current_zip_cached_job = nil
    @current_zip_active_job = nil
    @current_zip_failed_job = nil
    @current_zip_job = nil
    @current_zip_state = :unavailable
    @zip_busy = false
    @current_zip_total_task_count = @tasks.size
    @current_zip_generated_count = 0
    return unless @current_zip_signature.present?

    @current_zip_cached_job = @image_project.latest_completed_zip_job(input_signature: @current_zip_signature)
    @current_zip_active_job = active_zip_job_for_signature(@current_zip_signature) unless @current_zip_cached_job
    @current_zip_failed_job = @image_project.latest_failed_zip_job(input_signature: @current_zip_signature) unless @current_zip_cached_job || @current_zip_active_job
    @current_zip_job = @current_zip_cached_job || @current_zip_active_job || @current_zip_failed_job
    @current_zip_state = if @current_zip_cached_job
                           :cached
                         elsif @current_zip_active_job
                           @current_zip_active_job.status.to_sym
                         elsif @current_zip_failed_job
                           :failed
                         else
                           :missing
                         end
    @zip_busy = @current_zip_active_job.present?
    @current_zip_total_task_count = zip_total_task_count(@current_zip_job)
    @current_zip_generated_count = @current_zip_job&.generated_images&.count.to_i
  end

  def generation_job_status_payload(job)
    current_signature = ImageProjects::RenderInputSignature.full_zip(@image_project)
    {
      id: job.id,
      status: job.status,
      generation_scope: job.generation_scope,
      input_signature_matches: job.input_signature.to_s == current_signature.to_s,
      generated_image_count: job.generated_images.count,
      total_task_count: zip_total_task_count(job),
      warnings_summary: generation_message_summary(job.warnings_list),
      errors_summary: generation_message_summary(job.errors_list),
      downloadable: job.downloadable?,
      download_url: (generation_job_download_image_project_path(@image_project, job_id: job.id) if job.downloadable?),
      started_at: job.started_at&.iso8601,
      finished_at: job.finished_at&.iso8601,
      updated_at: job.updated_at&.iso8601
    }
  end

  def load_preview_generation_state
    @selected_preview_generation_job = nil
    @preview_all_generation_job = nil
    @current_preview_generation_job = nil
    @selected_preview_busy = false
    @preview_all_busy = false

    selected_signature = @selected_task_preview_signature if @selected_task_previewable
    if selected_signature.present?
      @selected_preview_generation_job = active_selected_preview_job_for(@selected_task_index, selected_signature) if @selected_task_preview.blank?
      @selected_preview_generation_job ||= failed_selected_preview_job_for(@selected_task_index, selected_signature)
    end

    all_signature = if @project_preview_all_available
                      ImageProjects::PreviewGenerationRunner.preview_all_signature(@image_project)
                    end
    if all_signature.present?
      @preview_all_generation_job = active_all_preview_job_for(all_signature) || failed_all_preview_job_for(all_signature)
    end

    @current_preview_generation_job = [ @selected_preview_generation_job, @preview_all_generation_job ].compact.find(&:active?) ||
                                      @selected_preview_generation_job ||
                                      @preview_all_generation_job
    @selected_preview_busy = @selected_preview_generation_job&.active? || selected_task_covered_by_all_preview_job?
    @preview_all_busy = @preview_all_generation_job&.active? || false
  end

  def selected_task_covered_by_all_preview_job?
    @preview_all_generation_job&.active? &&
      @preview_all_generation_job.task_indexes.include?(@selected_task_index.to_i)
  end

  def preview_generation_job_status_payload(job)
    task_indexes = job.task_indexes
    selected_index = selected_task_index
    current_match = preview_generation_job_matches_current_inputs?(job)
    preview_urls = current_preview_urls_for(job)
    selected_preview_url = preview_urls[selected_index.to_s] || preview_urls[task_indexes.first.to_s]
    {
      id: job.id,
      status: job.status,
      scope: job.scope,
      task_indexes: task_indexes,
      input_signature_matches: current_match,
      total_count: job.total_count,
      previewable_count: job.previewable_count,
      generated_count: job.generated_count,
      reused_count: job.reused_count,
      skipped_count: job.skipped_count,
      failed_count: job.failed_count,
      warnings_summary: generation_message_summary(job.warnings_list),
      errors_summary: generation_message_summary(job.errors_list),
      preview_url: selected_preview_url,
      preview_urls: preview_urls,
      message: preview_generation_status_message(job, current_match),
      updated_at: job.updated_at&.iso8601,
      finished_at: job.finished_at&.iso8601
    }
  end

  def preview_generation_job_matches_current_inputs?(job)
    if job.selected_task_preview?
      index = job.task_indexes.first
      return false if index.blank?

      preview_signature_for_task(index).to_s == job.input_signature.to_s
    elsif job.all_task_previews?
      ImageProjects::PreviewGenerationRunner.preview_all_signature(@image_project).to_s == job.input_signature.to_s
    else
      false
    end
  rescue StandardError
    false
  end

  def current_preview_urls_for(job)
    job.task_indexes.each_with_object({}) do |index, urls|
      task = @image_project.tasks[index]
      next if task.blank?

      task_name = task_display_name(task, index)
      input_signature = ImageProjects::RenderInputSignature.preview_task(@image_project, index)
      preview = current_task_preview_for(index, task_name, input_signature)
      next unless preview&.file&.attached?

      urls[index.to_s] = rails_blob_path(preview.file, only_path: true)
    end
  end

  def preview_generation_status_message(job, current_match)
    return "Preview job finished for older inputs. Save or preview again to update this task." unless current_match

    case job.status
    when "queued", "running"
      "Preview is being generated..."
    when "completed", "completed_with_errors"
      "Preview generation completed."
    when "failed"
      "Preview generation failed. Review the error summary and retry."
    else
      "Preview generation status is available."
    end
  end

  def active_selected_preview_job_for(task_index, input_signature)
    @image_project.preview_generation_jobs
      .for_signature(scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE, input_signature: input_signature)
      .active
      .order(created_at: :desc)
      .each do |job|
        next unless job.task_indexes == [ task_index.to_i ]
        next if refresh_stale_running_preview_job!(job)

        return job
      end

    nil
  end

  def failed_selected_preview_job_for(task_index, input_signature)
    @image_project.preview_generation_jobs
      .for_signature(scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE, input_signature: input_signature)
      .where(status: "failed")
      .order(updated_at: :desc)
      .detect { |job| job.task_indexes == [ task_index.to_i ] }
  end

  def active_all_preview_job_for(input_signature)
    @image_project.preview_generation_jobs
      .for_signature(scope: PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE, input_signature: input_signature)
      .active
      .order(created_at: :desc)
      .each do |job|
        next if refresh_stale_running_preview_job!(job)

        return job
      end

    nil
  end

  def failed_all_preview_job_for(input_signature)
    @image_project.preview_generation_jobs
      .for_signature(scope: PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE, input_signature: input_signature)
      .where(status: "failed")
      .order(updated_at: :desc)
      .first
  end

  def refresh_stale_running_preview_job!(job)
    return false unless job&.stale_running?

    job.update!(
      status: "failed",
      finished_at: Time.current,
      errors_list: Array(job.errors_list) + [ PreviewGenerationJob::STALE_RUNNING_MESSAGE ]
    )
    Rails.logger.warn(
      "Stale preview generation job marked failed image_project_id=#{@image_project.id} " \
      "preview_generation_job_id=#{job.id} scope=#{job.scope} signature=#{job.input_signature.to_s.first(12)}"
    )
    true
  end

  def generation_message_summary(messages)
    Array(messages).flat_map do |message|
      if message.is_a?(Hash)
        Array(message["warnings"] || message["errors"]).map { |entry| "#{message["targetName"]}: #{entry}" }
      else
        message.to_s
      end
    end.compact_blank.first(5)
  end

  def zip_total_task_count(job)
    return @image_project.tasks.size unless job&.task_indexes_json.present?

    parsed = JSON.parse(job.task_indexes_json)
    parsed.is_a?(Array) ? parsed.size : @image_project.tasks.size
  rescue JSON::ParserError
    @image_project.tasks.size
  end

  def save_request_config_if_present!
    return unless params.key?(:config_json_text) || params.key?(:task) || params.key?(:layers) || params.key?(:image_project)

    if params.key?(:config_json_text)
      save_raw_config
    else
      save_editor_config
    end
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
      "x" => layer.key?("x") ? scalar_position(layer["x"]) : (existing_layer&.dig("x") || 0),
      "y" => layer.key?("y") ? scalar_position(layer["y"]) : (existing_layer&.dig("y") || 0),
      "opacity" => decimal_param(layer["opacity"], 1)
    )
    common["notes"] = layer["notes"].to_s if layer.key?("notes")
    apply_relative_position_params!(common, layer)

    if type == "image"
      common.merge(
        "imageName" => layer["imageName"].to_s.strip,
        "width" => integer_param(layer["width"], 100),
        "height" => integer_param(layer["height"], 100),
        "fit" => %w[contain cover stretch].include?(layer["fit"].to_s) ? layer["fit"] : "contain"
      )
    else
      submitted_letter_spacing_mode =
        if layer.key?("letterSpacingMode")
          layer["letterSpacingMode"]
        else
          existing_layer&.dig("letterSpacingMode")
        end
      letter_spacing_mode = normalize_letter_spacing_mode(submitted_letter_spacing_mode)
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
        "notes" => common["notes"].to_s
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

      yield uploaded, files.size
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

  def global_font_upload_match_name(upload_count, filename)
    submitted = params.dig(:global_font_asset, :match_name).to_s.strip
    return submitted if upload_count == 1 && submitted.present?

    ImageProjects::AssetNameNormalizer.default_alias(filename)
  end

  def font_options_for(current_font)
    current_value = current_font.to_s.strip
    options = []
    options << [ "Browser fallback", "" ] if current_value.blank?

    if current_value.present?
      match = ImageProjects::FontMatcher.new(@image_project).match(current_value)
      if match.found? && !match.fallback?
        options << [ font_option_label(match.asset), current_value ] unless current_value == match.asset.name
      else
        options << [ "Missing/current: #{current_value} (Missing)", current_value ]
      end
    end

    font_option_assets.each do |asset|
      options << [ font_option_label(asset), asset.name ]
    end

    options.uniq { |_label, value| value }
  end

  def font_option_assets
    global = defined?(@global_font_assets) && @global_font_assets ? @global_font_assets : GlobalFontAsset.order(:name).to_a
    project_specific = defined?(@project_font_assets) && @project_font_assets ? @project_font_assets : @image_project.font_assets.order(:name).to_a

    (global + project_specific).select { |asset| font_asset_usable?(asset) }
  end

  def font_option_label(asset)
    "#{asset.name} (#{font_asset_scope_label(asset)})"
  end

  def font_asset_scope_label(asset)
    asset.is_a?(GlobalFontAsset) ? "Global" : "Project"
  end

  def font_asset_usable?(asset)
    asset.respond_to?(:file) && asset.file.attached?
  end

  def global_font_asset_referenced?(asset)
    ImageProject.find_each.any? do |project|
      project.tasks.any? do |task|
        Array(task["layers"]).any? do |layer|
          layer["type"].to_s == "text" && font_value_matches_global_asset?(layer["font"], asset)
        end
      end
    end
  end

  def font_value_matches_global_asset?(font_value, asset)
    query = font_value.to_s.strip
    return false if query.blank?

    full_query = ImageProjects::AssetNameNormalizer.full(query)
    return true if [ asset.name, asset.match_name ].compact_blank.any? { |name| ImageProjects::AssetNameNormalizer.full(name) == full_query }

    extensionless_query = ImageProjects::AssetNameNormalizer.extensionless(query)
    return true if [ asset.name, asset.normalized_name ].compact_blank.any? { |name| ImageProjects::AssetNameNormalizer.extensionless(name) == extensionless_query }

    loose_query = ImageProjects::AssetNameNormalizer.loose(query)
    [ asset.name, asset.normalized_name, asset.match_name ].compact_blank.any? do |name|
      ImageProjects::AssetNameNormalizer.loose(name) == loose_query
    end
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
    when /\Aswitch_to_absolute:(\d+)\z/
      switch_layer_to_absolute!(task, layers, Regexp.last_match(1).to_i)
    when /\Aswitch_to_relative:(\d+)\z/
      switch_layer_to_relative!(layers, Regexp.last_match(1).to_i)
    end
  end

  def apply_relative_position_params!(layer_config, layer_params)
    if layer_params.key?("relativeTo")
      relative_to = layer_params["relativeTo"].to_s.strip.presence
      if relative_to
        layer_config["relativeTo"] = relative_to
      else
        clear_relative_position!(layer_config)
      end
    end

    if layer_params.key?("relativePosition")
      relative_position = layer_params["relativePosition"].to_s.strip.presence
      if relative_position
        layer_config["relativePosition"] = relative_position
      else
        layer_config.delete("relativePosition")
      end
    end

    return unless layer_params.key?("relativeOffset")

    if layer_params["relativeOffset"].present?
      layer_config["relativeOffset"] = normalized_numeric_param(layer_params["relativeOffset"])
    else
      layer_config.delete("relativeOffset")
    end
  end

  def switch_layer_to_absolute!(task, layers, index)
    layer = layers[index]
    return unless layer

    layer["y"] = normalized_numeric_param(effective_layer_y(task, layers, index))
    backup_relative_position!(layer)
    clear_relative_position!(layer)
  end

  def switch_layer_to_relative!(layers, index)
    layer = layers[index]
    return unless layer

    if layer["previousRelativeTo"].present?
      layer["relativeTo"] = layer["previousRelativeTo"]
      layer["relativePosition"] = layer["previousRelativePosition"].presence || "below"
      if layer.key?("previousRelativeOffset") && layer["previousRelativeOffset"].present?
        layer["relativeOffset"] = normalized_numeric_param(layer["previousRelativeOffset"])
      else
        layer.delete("relativeOffset")
      end
      return
    end

    setup = relative_setup_params_for(index)
    relative_to = setup["relativeTo"].to_s.strip.presence
    return unless relative_to

    layer["relativeTo"] = relative_to
    layer["relativePosition"] = setup["relativePosition"].to_s.strip.presence || "below"
    if setup["relativeOffset"].present?
      layer["relativeOffset"] = normalized_numeric_param(setup["relativeOffset"])
    else
      layer.delete("relativeOffset")
    end
  end

  def relative_setup_params_for(index)
    setup = params.fetch(:relative_setup, {})
    setup = setup.permit!.to_h if setup.respond_to?(:permit!)
    setup.fetch(index.to_s, {})
  end

  def effective_layer_y(task, layers, index)
    task_for_resolution = task.deep_dup
    task_for_resolution["layers"] = layers.map(&:deep_dup)
    resolved = ImageProjects::Renderer.new(@image_project).resolved_layers_for(task_for_resolution)
    resolved[index]&.fetch("y", nil) || layers[index]["y"]
  rescue StandardError => error
    Rails.logger.warn("Relative position resolution failed while switching to absolute positioning: #{error.message}")
    layers[index]["y"]
  end

  def clear_relative_position!(layer)
    layer.delete("relativeTo")
    layer.delete("relativePosition")
    layer.delete("relativeOffset")
  end

  def backup_relative_position!(layer)
    return if layer["relativeTo"].blank?

    layer["previousRelativeTo"] = layer["relativeTo"]
    layer["previousRelativePosition"] = layer["relativePosition"].presence || "below"
    if layer.key?("relativeOffset") && layer["relativeOffset"].present?
      layer["previousRelativeOffset"] = normalized_numeric_param(layer["relativeOffset"])
    else
      layer.delete("previousRelativeOffset")
    end
  end

  def ensure_task_previewable!(index)
    task = @image_project.tasks[index]
    readiness = task_preview_readiness(task)
    raise readiness[:alert] unless readiness[:ready]
  end

  def ensure_project_downloadable!
    readiness = project_download_readiness(@image_project.tasks)
    raise readiness[:alert] unless readiness[:ready]
  end

  def task_preview_readiness(task)
    ImageProjects::TaskPreviewReadiness.call(@image_project, task)
  end

  def project_preview_all_readiness(tasks)
    task_list = Array(tasks)
    readiness_checker = ImageProjects::TaskPreviewReadiness.new(@image_project)
    readinesses = task_list.map { |task| readiness_checker.call(task) }
    return { ready: true, message: nil, alert: nil } if readinesses.any? { |readiness| readiness[:ready] }

    first_readiness = readinesses.find { |readiness| readiness[:message].present? || readiness[:alert].present? }
    {
      ready: false,
      message: first_readiness&.fetch(:message, nil) || "Import Excel or add at least one previewable task.",
      alert: first_readiness&.fetch(:alert, nil) || "Please import Excel or add at least one previewable task."
    }
  end

  def project_download_readiness(tasks)
    task_list = Array(tasks)
    if task_list.empty? || task_list.none? { |task| Array(task["layers"]).any? { |layer| renderable_layer?(layer) } }
      return {
        ready: false,
        message: "Import Excel or add at least one renderable layer before downloading the ZIP.",
        alert: "Please import Excel or add layers before downloading the ZIP."
      }
    end

    missing_images = missing_required_images_for_tasks(task_list)
    if missing_images.any?
      return {
        ready: false,
        message: "Upload the required source images before downloading the ZIP: #{missing_images.join(', ')}.",
        alert: "Please upload the required source images before downloading the ZIP."
      }
    end

    { ready: true, message: nil, alert: nil }
  end

  def renderable_layer?(layer)
    case layer["type"].to_s
    when "text"
      ImageProjects::InlineTextParser.plain_text(layer["text"]).strip.present?
    when "image"
      layer["imageName"].to_s.strip.present?
    else
      false
    end
  end

  def missing_required_images_for_tasks(tasks)
    image_matcher = ImageProjects::ImageMatcher.new(@image_project)
    Array(tasks).flat_map do |task|
      Array(task && task["layers"]).filter_map do |layer|
        next unless layer["type"].to_s == "image"

        image_name = layer["imageName"].to_s.strip
        next if image_name.blank?

        match = image_matcher.match(image_name)
        next if match.found? && match.asset.file.attached?

        image_name
      end
    end.uniq
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
          if match.found? && match.asset.file.attached?
            warnings << match.warning if match.warning.present?
            next
          end

          missing_image = true
          errors << if match.found?
                      "Task #{target_name} could not be generated because source image \"#{image_name}\" matched \"#{match.asset.name}\", but the uploaded asset has no attached file."
                    else
                      "Task #{target_name} could not be generated because source image \"#{image_name}\" was not found."
                    end
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
    if match.found? && !match.fallback?
      { name: name, status: "matched", message: "#{name} matched to #{match.asset.name}" }
    else
      { name: name, status: "warning", message: match.warning.presence || missing_font_message(name) }
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
    current_task_preview_for(index, task_name).present?
  end

  def preview_signature_for_task(index)
    return nil if @image_project.tasks[index].blank?

    ImageProjects::RenderInputSignature.preview_task(@image_project, index)
  end

  def current_task_preview_for(index, task_name = nil, input_signature = nil)
    task = @image_project.tasks[index]
    return nil if task.blank?

    task_name ||= task_display_name(task, index)
    input_signature ||= preview_signature_for_task(index)
    return nil if input_signature.blank?

    @image_project.task_previews
      .with_attached_file
      .where(task_index: index, task_name: task_name, input_signature: input_signature)
      .order(created_at: :desc)
      .detect { |preview| preview.file.attached? }
  end

  def stale_task_preview_for(index, current_preview = nil)
    @image_project.task_previews
      .with_attached_file
      .where(task_index: index)
      .where.not(id: current_preview&.id)
      .order(created_at: :desc)
      .detect { |preview| preview.file.attached? }
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

  def normalized_numeric_param(value)
    number = decimal_param(value, 0)
    number == number.to_i ? number.to_i : number
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
