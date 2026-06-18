require "test_helper"
require "base64"
require "stringio"

class ImageProjectsControllerTaskSelectionTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
  FakeJob = Struct.new(:status, :generated_images, :zip_file)
  FakeZipBlob = Struct.new(:bytes) do
    def download
      yield bytes
    end
  end
  FakeZipFile = Struct.new(:filename, :blob) do
    def attached?
      true
    end
  end

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "task list renders selectable P1 and P2 cards" do
    project = create_project_with_tasks

    get image_project_path(project)

    assert_response :success
    assert_select ".task-panel h2", text: "Select Task"
    assert_select ".task-title", text: "P1"
    assert_select ".task-title", text: "P2"
    assert_select "a.task-select-card[href='#{image_project_path(project, task_index: 0)}']" do
      assert_select ".selection-badge", text: "Selected"
    end
    assert_select "a.task-select-card[href='#{image_project_path(project, task_index: 1)}']" do
      assert_select ".selection-badge", text: "Select"
    end
    assert_includes response.body, "Select a task below to preview that image."
    assert_select "details.background-status-block[open]", count: 0
  end

  test "task index one selects P2 across actions preview settings and warnings" do
    project = create_project_with_tasks

    get image_project_path(project, task_index: 1)

    assert_response :success
    assert_select "a.task-select-card[aria-current='page'][href='#{image_project_path(project, task_index: 1)}']" do
      assert_select ".task-title", text: "P2"
      assert_select ".selection-badge", text: "Selected"
    end
    assert_includes response.body, "Selected Image: <strong>P2</strong>"
    assert_includes response.body, "Preview Selected Image"
    assert_includes response.body, "Preview All Images"
    assert_includes response.body, "Generate ZIP (All Images)"
    refute_includes response.body, "Generate P2"
    assert_includes response.body, "Preview for P2"
    assert_includes response.body, "Warnings / Errors for P2"
    assert_select "details.warnings-panel.has-warnings"
    assert_select "details.warnings-panel.has-warnings[open]", count: 0
    assert_select "details.warnings-panel.has-errors", count: 0
    assert_select "input[name='task[targetName]'][value='P2']"
    assert_select "input[name='task[canvas][width]'][value='220']"
    assert_select "select[name='task[output][format]'] option[selected='selected'][value='jpg']"
  end

  test "step three shows current zip cache active and failed states" do
    cached_project = create_project_with_tasks
    cached_signature = ImageProjects::RenderInputSignature.full_zip(cached_project)
    attach_zip_job(
      cached_project,
      input_signature: cached_signature,
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      bytes: "zip"
    )

    get image_project_path(cached_project)
    assert_response :success
    assert_includes response.body, "Download ZIP (All Images)"
    assert_select ".generate-step button[data-operation-action='zip']", text: "Download ZIP (All Images)"
    assert_select ".zip-status-panel.status-completed"
    assert_select "details.background-status-block[open]", count: 0
    assert_select ".zip-status-panel.status-completed [data-zip-status-spinner][hidden]"

    running_project = create_project_with_tasks
    running_signature = ImageProjects::RenderInputSignature.full_zip(running_project)
    running_project.image_generation_jobs.create!(
      status: "running",
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      input_signature: running_signature,
      started_at: Time.current
    )

    get image_project_path(running_project)
    assert_response :success
    assert_select ".generate-step button[data-operation-action='zip'][disabled='disabled']", text: "Generate ZIP (All Images)"
    assert_select ".operation-status-chip", count: 0
    assert_select ".zip-status-panel.status-running[data-poll='true']"
    assert_select "details.background-status-block[open]"
    assert_select ".zip-status-panel.status-running [data-zip-status-spinner]"
    assert_select ".zip-status-panel.status-running [data-zip-status-spinner][hidden]", count: 0
    assert_includes response.body, "This may take a while for many images."

    failed_project = create_project_with_tasks
    failed_signature = ImageProjects::RenderInputSignature.full_zip(failed_project)
    failed_job = failed_project.image_generation_jobs.create!(
      status: "failed",
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      input_signature: failed_signature,
      started_at: 1.minute.ago,
      finished_at: Time.current
    )
    failed_job.errors_list = [ "render failed" ]
    failed_job.save!

    get image_project_path(failed_project)
    assert_response :success
    assert_select ".zip-status-panel.status-failed"
    assert_select "details.background-status-block[open]"
    assert_includes response.body, "render failed"
  end

  test "preview panel does not show P1 preview as P2 preview" do
    project = create_project_with_tasks
    attach_preview(project, task_index: 0, task_name: "P1")

    get image_project_path(project, task_index: 1)

    assert_response :success
    assert_select "img.preview-image", count: 0
    assert_includes response.body, "No up-to-date preview generated for P2 yet."
    assert_includes response.body, "Click Preview Selected Image to generate one."

    get image_project_path(project, task_index: 0)

    assert_response :success
    assert_select "img.preview-image", count: 1
    assert_includes response.body, "Preview for P1"
  end

  test "preview action enqueues selected task preview without rendering in request" do
    project = create_project_with_tasks
    old_blob = attach_preview(project, task_index: 0, task_name: "P1")

    with_singleton_method_stub(ImageProjects::Renderer, :new, ->(_project) { flunk "preview request should not render synchronously" }) do
      assert_enqueued_jobs 1, only: ImageProjects::GeneratePreviewJob do
        post preview_image_project_path(project, task_index: 1)
      end
    end

    assert_redirected_to image_project_path(project, task_index: 1)
    project.reload
    assert_equal 1, project.task_previews.count
    assert ActiveStorage::Blob.exists?(old_blob.id)
    assert old_blob.service.exist?(old_blob.key)
    preview_job = project.preview_generation_jobs.order(:created_at).last
    assert_equal "queued", preview_job.status
    assert_equal PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE, preview_job.scope
    assert_equal [ 1 ], preview_job.task_indexes
    assert_equal ImageProjects::RenderInputSignature.preview_task(project, 1), preview_job.input_signature
    assert_equal [ preview_job.id ], enqueued_jobs.last[:args]
  end

  test "update preview action saves selected task settings before enqueueing preview job" do
    project = create_project_with_tasks
    preview_text = "**DESIGN** HIGHLIGHTS"

    with_singleton_method_stub(ImageProjects::Renderer, :new, ->(_project) { flunk "preview request should not render synchronously" }) do
      assert_enqueued_jobs 1, only: ImageProjects::GeneratePreviewJob do
        patch image_project_path(project), params: editor_update_params(
          index: 1,
          target_name: "P2",
          layer: text_layer_update_params("P2", "text" => preview_text, "fontSize" => "77"),
          after_save_action: "preview_current"
        )
      end
    end

    assert_redirected_to image_project_path(project, task_index: 1)
    project.reload
    assert_equal preview_text, project.config_hash.dig("tasks", 1, "layers", 0, "text")
    assert_equal 77, project.config_hash.dig("tasks", 1, "layers", 0, "fontSize")
    preview_job = project.preview_generation_jobs.order(:created_at).last
    assert_equal "queued", preview_job.status
    assert_equal [ 1 ], preview_job.task_indexes
    assert_equal ImageProjects::RenderInputSignature.preview_task(project, 1), preview_job.input_signature
  end

  test "performing selected preview job stores preview for selected task" do
    project = create_project_with_tasks
    renderer = Object.new
    test_case = self
    renderer.define_singleton_method(:render_preview) do |task, scale:|
      test_case.assert_equal "P2", task["targetName"]
      test_case.assert_equal 0.5, scale
      test_case.send(:preview_result_for, task["targetName"])
    end

    with_singleton_method_stub(ImageProjects::Renderer, :new, ->(_project) { renderer }) do
      perform_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
        post preview_image_project_path(project, task_index: 1)
      end
    end

    assert_redirected_to image_project_path(project, task_index: 1)
    p2_preview = project.reload.task_previews.find_by!(task_index: 1)
    assert p2_preview.file.attached?
    assert_equal "P2", p2_preview.task_name
    assert_equal "completed", project.preview_generation_jobs.last.status
  end

  test "update preview action returns cached preview immediately without enqueueing" do
    project = create_project_with_tasks
    patch image_project_path(project), params: editor_update_params(
      index: 1,
      target_name: "P2",
      layer: text_layer_update_params("P2"),
      after_save_action: nil
    )
    project.reload
    attach_preview(project, task_index: 1, task_name: "P2")

    assert_no_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
      patch image_project_path(project), params: editor_update_params(
        index: 1,
        target_name: "P2",
        layer: text_layer_update_params("P2"),
        after_save_action: "preview_current"
      )
    end

    assert_redirected_to image_project_path(project, task_index: 1)
    assert_equal 0, project.preview_generation_jobs.count
  end

  test "ajax selected preview cache hit returns preview url without enqueueing" do
    project = create_project_with_tasks
    patch image_project_path(project), params: editor_update_params(
      index: 1,
      target_name: "P2",
      layer: text_layer_update_params("P2"),
      after_save_action: nil
    )
    project.reload
    attach_preview(project, task_index: 1, task_name: "P2")

    assert_no_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
      patch image_project_path(project), params: editor_update_params(
        index: 1,
        target_name: "P2",
        layer: text_layer_update_params("P2"),
        after_save_action: "preview_current"
      ), headers: { "Accept" => "application/json" }
    end

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "cached", payload["state"]
    assert_equal "completed", payload["status"]
    assert_match %r{/rails/active_storage/}, payload["preview_url"]
    assert_nil payload["job_id"]
  end

  test "ajax selected preview cache miss returns queued job status without rendering" do
    project = create_project_with_tasks

    with_singleton_method_stub(ImageProjects::Renderer, :new, ->(_project) { flunk "ajax preview should not render synchronously" }) do
      assert_enqueued_jobs 1, only: ImageProjects::GeneratePreviewJob do
        patch image_project_path(project), params: editor_update_params(
          index: 1,
          target_name: "P2",
          layer: text_layer_update_params("P2", "text" => "AJAX preview text"),
          after_save_action: "preview_current"
        ), headers: { "Accept" => "application/json" }
      end
    end

    assert_response :success
    payload = JSON.parse(response.body)
    preview_job = project.preview_generation_jobs.last
    assert_equal "queued", payload["state"]
    assert_equal preview_job.id, payload["job_id"]
    assert_equal preview_generation_job_status_image_project_path(project, job_id: preview_job.id, task_index: 1), payload["status_url"]
  end

  test "preview generation status returns completed selected preview url" do
    project = create_project_with_tasks
    renderer = Object.new
    test_case = self
    renderer.define_singleton_method(:render_preview) do |task, scale:|
      test_case.assert_equal 0.5, scale
      test_case.send(:preview_result_for, task["targetName"])
    end

    with_singleton_method_stub(ImageProjects::Renderer, :new, ->(_project) { renderer }) do
      perform_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
        post preview_image_project_path(project, task_index: 1)
      end
    end

    preview_job = project.preview_generation_jobs.last
    get preview_generation_job_status_image_project_path(project, job_id: preview_job.id, task_index: 1)

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal preview_job.id, payload["id"]
    assert_equal "completed", payload["status"]
    assert_equal true, payload["input_signature_matches"]
    assert_equal 1, payload["generated_count"]
    assert_match %r{/rails/active_storage/}, payload["preview_url"]
  end

  test "preview generation status marks stale running job failed" do
    project = create_project_with_tasks
    input_signature = ImageProjects::RenderInputSignature.preview_task(project, 1)
    preview_job = create_preview_generation_job(
      project,
      status: "running",
      scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE,
      task_indexes: [ 1 ],
      input_signature: input_signature
    )
    preview_job.update_columns(started_at: 2.hours.ago, updated_at: 2.hours.ago)

    get preview_generation_job_status_image_project_path(project, job_id: preview_job.id, task_index: 1)

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "failed", payload["status"]
    assert_includes payload["errors_summary"], PreviewGenerationJob::STALE_RUNNING_MESSAGE
    assert_equal "failed", preview_job.reload.status
    assert preview_job.finished_at.present?
  end

  test "project page resumes polling for queued selected preview job" do
    project = create_project_with_tasks
    input_signature = ImageProjects::RenderInputSignature.preview_task(project, 1)
    preview_job = project.preview_generation_jobs.create!(
      status: "queued",
      scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE,
      task_indexes_json: JSON.generate([ 1 ]),
      task_signatures_json: JSON.generate("1" => input_signature),
      input_signature: input_signature,
      total_count: 1,
      previewable_count: 1
    )

    get image_project_path(project, task_index: 1)

    assert_response :success
    assert_select ".generate-step button[data-operation-action='selected-preview'][disabled='disabled']", text: "Preview Selected Image"
    assert_select ".operation-status-chip", count: 0
    assert_select ".preview-status-panel.status-queued[data-poll='true'][data-status-url='#{preview_generation_job_status_image_project_path(project, job_id: preview_job.id, task_index: 1)}']"
    assert_select "details.background-status-block[open]"
    assert_select ".preview-status-panel.status-queued [data-preview-status-spinner]"
    assert_select ".preview-status-panel.status-queued [data-preview-status-spinner][hidden]", count: 0
    assert_includes response.body, "Preview is being generated..."
  end

  test "project page disables preview all button while matching preview-all job is running" do
    project = create_project_with_tasks([ "P1", "P2" ])
    input_signature = ImageProjects::PreviewGenerationRunner.preview_all_signature(project)
    preview_job = project.preview_generation_jobs.create!(
      status: "running",
      scope: PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE,
      task_indexes_json: JSON.generate([ 0, 1 ]),
      task_signatures_json: JSON.generate(
        "0" => ImageProjects::RenderInputSignature.preview_task(project, 0),
        "1" => ImageProjects::RenderInputSignature.preview_task(project, 1)
      ),
      input_signature: input_signature,
      total_count: 2,
      previewable_count: 2,
      generated_count: 1
    )

    get image_project_path(project, task_index: 1)

    assert_response :success
    assert_select ".generate-step button[data-operation-action='preview-all'][disabled='disabled']", text: "Preview All Images"
    assert_select ".generate-step button[data-operation-action='selected-preview'][disabled='disabled']", text: "Preview Selected Image"
    assert_select ".operation-status-chip", count: 0
    assert_select ".preview-status-panel.status-running[data-poll='true'][data-status-url='#{preview_generation_job_status_image_project_path(project, job_id: preview_job.id, task_index: 1)}']"
    assert_select "details.background-status-block[open]"
    assert_select ".preview-status-panel.status-running [data-preview-status-spinner][hidden]", count: 0
  end

  test "project page expands failed preview job status without spinner" do
    project = create_project_with_tasks
    input_signature = ImageProjects::RenderInputSignature.preview_task(project, 1)
    preview_job = create_preview_generation_job(
      project,
      status: "failed",
      scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE,
      task_indexes: [ 1 ],
      input_signature: input_signature
    )
    preview_job.errors_list = [ "preview failed" ]
    preview_job.save!

    get image_project_path(project, task_index: 1)

    assert_response :success
    assert_select "details.background-status-block[open]"
    assert_select ".preview-status-panel.status-failed"
    assert_select ".preview-status-panel.status-failed [data-preview-status-spinner][hidden]"
    assert_includes response.body, "preview failed"
  end

  test "project page fails stale running selected preview job and next preview queues new job" do
    project = create_project_with_tasks
    input_signature = ImageProjects::RenderInputSignature.preview_task(project, 1)
    stale_job = create_preview_generation_job(
      project,
      status: "running",
      scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE,
      task_indexes: [ 1 ],
      input_signature: input_signature
    )
    stale_job.update_columns(started_at: 2.hours.ago, updated_at: 2.hours.ago)

    get image_project_path(project, task_index: 1)

    assert_response :success
    assert_equal "failed", stale_job.reload.status
    assert_includes stale_job.errors_list, PreviewGenerationJob::STALE_RUNNING_MESSAGE
    assert_select ".preview-status-panel.status-running", count: 0

    assert_enqueued_jobs 1, only: ImageProjects::GeneratePreviewJob do
      post preview_image_project_path(project, task_index: 1)
    end

    assert_redirected_to image_project_path(project, task_index: 1)
    new_job = project.preview_generation_jobs.order(:created_at).last
    refute_equal stale_job.id, new_job.id
    assert_equal "queued", new_job.status
    assert_equal [ 1 ], new_job.task_indexes
  end

  test "re-clicking selected preview while matching job is running reuses same job" do
    project = create_project_with_tasks
    input_signature = ImageProjects::RenderInputSignature.preview_task(project, 1)
    existing_job = create_preview_generation_job(
      project,
      status: "running",
      scope: PreviewGenerationJob::SELECTED_TASK_PREVIEW_SCOPE,
      task_indexes: [ 1 ],
      input_signature: input_signature
    )

    assert_no_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
      post preview_image_project_path(project, task_index: 1)
    end

    assert_redirected_to image_project_path(project, task_index: 1)
    assert_equal [ existing_job.id ], project.preview_generation_jobs.pluck(:id)
  end

  test "re-clicking preview all while matching job is running reuses same job" do
    project = create_project_with_tasks([ "P1", "P2" ])
    input_signature = ImageProjects::PreviewGenerationRunner.preview_all_signature(project)
    existing_job = create_preview_generation_job(
      project,
      status: "running",
      scope: PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE,
      task_indexes: [ 0, 1 ],
      input_signature: input_signature
    )

    assert_no_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
      post preview_all_image_project_path(project)
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal [ existing_job.id ], project.preview_generation_jobs.pluck(:id)
  end

  test "update preview all action saves selected task settings once and enqueues missing previews" do
    project = create_project_with_tasks([ "P1", "P2", "P3" ])
    preview_text = "P2 bulk preview text"

    with_singleton_method_stub(ImageProjects::Renderer, :new, ->(_project) { flunk "preview all request should not render synchronously" }) do
      assert_enqueued_jobs 1, only: ImageProjects::GeneratePreviewJob do
        patch image_project_path(project), params: editor_update_params(
          index: 1,
          target_name: "P2",
          layer: text_layer_update_params("P2", "text" => preview_text),
          after_save_action: "preview_all"
        )
      end
    end

    assert_equal "update", @controller.action_name
    assert_redirected_to image_project_path(project, task_index: 1)
    assert_equal preview_text, project.reload.config_hash.dig("tasks", 1, "layers", 0, "text")
    assert_equal [], project.task_previews.order(:task_index).pluck(:task_index)
    preview_job = project.preview_generation_jobs.order(:created_at).last
    assert_equal PreviewGenerationJob::ALL_TASK_PREVIEWS_SCOPE, preview_job.scope
    assert_equal [ 0, 1, 2 ], preview_job.task_indexes
    assert_equal 3, preview_job.previewable_count
    assert_equal 0, preview_job.reused_count
    follow_redirect!
    assert_includes response.body, "Configuration saved. Preview generation started for 3 tasks."
  end

  test "preview all update action reuses cached previews and queues only stale or missing tasks" do
    project = create_project_with_tasks([ "P1", "P2" ])
    attach_preview(project, task_index: 0, task_name: "P1")

    with_singleton_method_stub(ImageProjects::Renderer, :new, ->(_project) { flunk "preview all request should not render synchronously" }) do
      assert_enqueued_jobs 1, only: ImageProjects::GeneratePreviewJob do
        patch image_project_path(project), params: editor_update_params(
          index: 1,
          target_name: "P2",
          layer: text_layer_update_params("P2"),
          after_save_action: "preview_all"
        )
      end
    end

    assert_redirected_to image_project_path(project, task_index: 1)
    preview_job = project.preview_generation_jobs.order(:created_at).last
    assert_equal [ 1 ], preview_job.task_indexes
    assert_equal 1, preview_job.reused_count
    follow_redirect!
    assert_includes response.body, "Configuration saved. Preview generation started for 1 task."
  end

  test "preview all uses one renderer batch when background job performs" do
    project = create_project_with_tasks([ "P1", "P2", "P3" ])
    rendered_names = []
    batch_count = 0
    renderer = Object.new
    test_case = self
    renderer.define_singleton_method(:with_reused_browser) do |&block|
      batch_count += 1
      block.call
    end
    renderer.define_singleton_method(:render_preview) do |task, scale:|
      rendered_names << task["targetName"]
      test_case.assert_equal 0.5, scale
      test_case.send(:preview_result_for, task["targetName"])
    end

    with_singleton_method_stub(ImageProjects::Renderer, :new, ->(_project) { renderer }) do
      perform_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
      patch image_project_path(project), params: editor_update_params(
        index: 1,
        target_name: "P2",
        layer: text_layer_update_params("P2"),
        after_save_action: "preview_all"
      )
      end
    end

    assert_equal [ "P1", "P2", "P3" ], rendered_names
    assert_equal 1, batch_count
    assert_equal [ 0, 1, 2 ], project.task_previews.order(:task_index).pluck(:task_index)
  end

  test "previewing P1 then P2 keeps P1 preview available when returning to P1" do
    project = create_project_with_tasks
    renderer = Object.new
    test_case = self
    renderer.define_singleton_method(:render_preview) do |task, scale:|
      test_case.assert_equal 0.5, scale

      test_case.send(:preview_result_for, task["targetName"])
    end

    renderer_factory = lambda { |_project| renderer }
    with_singleton_method_stub(ImageProjects::Renderer, :new, renderer_factory) do
      perform_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
        post preview_image_project_path(project, task_index: 0)
        assert_redirected_to image_project_path(project, task_index: 0)
      end

      perform_enqueued_jobs only: ImageProjects::GeneratePreviewJob do
        post preview_image_project_path(project, task_index: 1)
        assert_redirected_to image_project_path(project, task_index: 1)
      end
    end

    project.reload
    assert_equal [ 0, 1 ], project.task_previews.order(:task_index).pluck(:task_index)

    get image_project_path(project, task_index: 0)

    assert_response :success
    assert_select "img.preview-image", count: 1
    assert_includes response.body, "Scaled preview for P1"
  end

  test "preview cache is ignored after selected task config changes" do
    project = create_project_with_tasks
    attach_preview(project, task_index: 0, task_name: "P1")

    patch image_project_path(project), params: editor_update_params(
      index: 0,
      target_name: "P1",
      layer: text_layer_update_params("P1", "text" => "Changed copy"),
      after_save_action: nil
    )

    assert_redirected_to image_project_path(project, task_index: 0)

    get image_project_path(project, task_index: 0)

    assert_response :success
    assert_select "img.preview-image", count: 0
    assert_includes response.body, "No up-to-date preview generated for P1 yet."
    assert_includes response.body, "An older preview for P1 is outdated."
  end

  test "stale preview is ignored when matched source image blob changes" do
    project = create_project_with_image_task
    asset = attach_image_asset(project, "source.png")
    attach_preview(project, task_index: 0, task_name: "P1")

    get image_project_path(project, task_index: 0)
    assert_response :success
    assert_select "img.preview-image", count: 1

    asset.file.purge
    asset.file.attach(io: StringIO.new("replacement image bytes"), filename: "source.png", content_type: "image/png")

    get image_project_path(project, task_index: 0)

    assert_response :success
    assert_select "img.preview-image", count: 0
    assert_includes response.body, "An older preview for P1 is outdated."
  end

  test "legacy update generate current saves selected task settings but does not generate synchronously" do
    project = create_project_with_tasks

    with_singleton_method_stub(ImageProjects::GenerationRunner, :call, ->(*_args, **_kwargs) { flunk "generate_current should not run final generation synchronously" }) do
      patch image_project_path(project), params: editor_update_params(
        index: 1,
        target_name: "P2",
        layer: text_layer_update_params("P2", "text" => "P2 current generation text"),
        after_save_action: "generate_current"
      )
    end

    assert_redirected_to image_project_path(project, task_index: 1)
    assert_equal "P2 current generation text", project.reload.config_hash.dig("tasks", 1, "layers", 0, "text")
    follow_redirect!
    assert_includes response.body, "Current-image final generation is no longer run in the request."
  end

  test "legacy update generate all saves selected task settings and uses background zip generation" do
    project = create_project_with_tasks

    with_singleton_method_stub(ImageProjects::GenerationRunner, :call, ->(*_args, **_kwargs) { flunk "generate_all should not run final generation synchronously" }) do
      assert_enqueued_jobs 1, only: ImageProjects::GenerateZipJob do
        patch image_project_path(project), params: editor_update_params(
          index: 1,
          target_name: "P2",
          layer: text_layer_update_params("P2", "text" => "P2 all generation text"),
          after_save_action: "generate_all"
        )
      end
    end

    assert_redirected_to image_project_path(project, task_index: 1)
    assert_equal "P2 all generation text", project.reload.config_hash.dig("tasks", 1, "layers", 0, "text")
    queued_job = project.image_generation_jobs.order(:created_at).last
    assert_equal "queued", queued_job.status
    assert_equal ImageGenerationJob::ALL_TASKS_ZIP_SCOPE, queued_job.generation_scope
  end

  test "direct generate route uses background zip generation" do
    project = create_project_with_tasks

    with_singleton_method_stub(ImageProjects::GenerationRunner, :call, ->(*_args, **_kwargs) { flunk "direct generate should not run final generation synchronously" }) do
      assert_enqueued_jobs 1, only: ImageProjects::GenerateZipJob do
        post generate_image_project_path(project)
      end
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal "queued", project.image_generation_jobs.last.status
  end

  test "ajax generate zip returns queued json without synchronous generation" do
    project = create_project_with_tasks

    with_singleton_method_stub(ImageProjects::GenerationRunner, :call, ->(*_args, **_kwargs) { flunk "ajax zip should not run final generation synchronously" }) do
      assert_enqueued_jobs 1, only: ImageProjects::GenerateZipJob do
        patch image_project_path(project), params: editor_update_params(
          index: 1,
          target_name: "P2",
          layer: text_layer_update_params("P2", "text" => "AJAX ZIP text"),
          after_save_action: "download_zip"
        ), headers: { "Accept" => "application/json" }
      end
    end

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "queued", payload["state"]
    assert_equal "queued", payload["status"]
    assert_equal project.image_generation_jobs.last.id, payload["job_id"]
    assert_equal generation_job_status_image_project_path(project, job_id: payload["job_id"]), payload["status_url"]
    assert_equal false, payload["downloadable"]
  end

  test "ajax cached zip returns download url without enqueueing" do
    project = create_project_with_tasks
    patch image_project_path(project), params: editor_update_params(
      index: 0,
      target_name: "P1",
      layer: text_layer_update_params("P1"),
      after_save_action: nil
    )
    project.reload
    signature = ImageProjects::RenderInputSignature.full_zip(project)
    cached_job = attach_zip_job(
      project,
      input_signature: signature,
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      bytes: "zip"
    )

    assert_no_enqueued_jobs only: ImageProjects::GenerateZipJob do
      patch image_project_path(project), params: editor_update_params(
        index: 0,
        target_name: "P1",
        layer: text_layer_update_params("P1"),
        after_save_action: "download_zip"
      ), headers: { "Accept" => "application/json" }
    end

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal "cached", payload["state"]
    assert_equal true, payload["downloadable"]
    assert_equal generation_job_download_image_project_path(project, job_id: cached_job.id), payload["download_url"]
  end

  test "update download zip saves selected task settings and enqueues background generation" do
    project = create_project_with_tasks
    zip_text = "**DESIGN** HIGHLIGHTS"

    assert_enqueued_jobs 1, only: ImageProjects::GenerateZipJob do
      patch image_project_path(project), params: editor_update_params(
        index: 1,
        target_name: "P2",
        layer: text_layer_update_params("P2", "text" => zip_text),
        after_save_action: "download_zip"
      )
    end

    assert_redirected_to image_project_path(project, task_index: 1)
    assert_equal zip_text, project.reload.config_hash.dig("tasks", 1, "layers", 0, "text")
    queued_job = project.image_generation_jobs.order(:created_at).last
    assert_equal "queued", queued_job.status
    assert_equal ImageGenerationJob::ALL_TASKS_ZIP_SCOPE, queued_job.generation_scope
    assert_equal ImageProjects::RenderInputSignature.full_zip(project), queued_job.input_signature
    assert_equal [ queued_job.id ], enqueued_jobs.last[:args]
  end

  test "download zip redirects to matching cached job when inputs are unchanged" do
    project = create_project_with_tasks
    signature = ImageProjects::RenderInputSignature.full_zip(project)
    cached_job = attach_zip_job(
      project,
      input_signature: signature,
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      bytes: "zip-1"
    )

    assert_no_enqueued_jobs only: ImageProjects::GenerateZipJob do
      get download_zip_image_project_path(project)
    end

    assert_redirected_to rails_blob_path(cached_job.zip_file, disposition: "attachment")
    assert_equal 1, project.image_generation_jobs.count
  end

  test "download zip get does not start generation when cache is missing" do
    project = create_project_with_tasks

    assert_no_enqueued_jobs only: ImageProjects::GenerateZipJob do
      get download_zip_image_project_path(project)
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal 0, project.image_generation_jobs.count
  end

  test "queued zip generation is reused for matching signature" do
    project = create_project_with_tasks
    patch image_project_path(project), params: editor_update_params(
      index: 0,
      target_name: "P1",
      layer: text_layer_update_params("P1"),
      after_save_action: nil
    )
    project.reload
    signature = ImageProjects::RenderInputSignature.full_zip(project)
    existing_job = project.image_generation_jobs.create!(
      status: "queued",
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      input_signature: signature
    )
    clear_enqueued_jobs

    assert_no_enqueued_jobs only: ImageProjects::GenerateZipJob do
      patch image_project_path(project), params: editor_update_params(
        index: 0,
        target_name: "P1",
        layer: text_layer_update_params("P1"),
        after_save_action: "download_zip"
      )
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal [ existing_job.id ], project.image_generation_jobs.pluck(:id)
  end

  test "stale running zip generation is failed and replacement can be queued" do
    project = create_project_with_tasks
    patch image_project_path(project), params: editor_update_params(
      index: 0,
      target_name: "P1",
      layer: text_layer_update_params("P1"),
      after_save_action: nil
    )
    project.reload
    signature = ImageProjects::RenderInputSignature.full_zip(project)
    stale_job = project.image_generation_jobs.create!(
      status: "running",
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      input_signature: signature
    )
    stale_job.update_columns(started_at: 2.hours.ago, updated_at: 2.hours.ago)

    assert_enqueued_jobs 1, only: ImageProjects::GenerateZipJob do
      patch image_project_path(project), params: editor_update_params(
        index: 0,
        target_name: "P1",
        layer: text_layer_update_params("P1"),
        after_save_action: "download_zip"
      )
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal "failed", stale_job.reload.status
    assert stale_job.errors_list.any? { |message| message.include?("ZIP generation was marked failed") }
    new_job = project.image_generation_jobs.order(:created_at).last
    refute_equal stale_job.id, new_job.id
    assert_equal "queued", new_job.status
    assert_equal ImageGenerationJob::ALL_TASKS_ZIP_SCOPE, new_job.generation_scope
  end

  test "download zip cache invalidates when matched font file changes" do
    project = create_project_with_tasks([ "P1" ])
    config = project.config_hash
    config["tasks"][0]["layers"][0]["font"] = "Brand"
    project.update_config!(config)
    font = create_global_font_asset("Brand.ttf", bytes: "font-v1")
    old_signature = ImageProjects::RenderInputSignature.full_zip(project)
    old_job = attach_zip_job(
      project,
      input_signature: old_signature,
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      bytes: "zip-1"
    )

    font.file.purge
    font.file.attach(io: StringIO.new("font-v2"), filename: "Brand.ttf", content_type: "font/ttf")

    assert_enqueued_jobs 1, only: ImageProjects::GenerateZipJob do
      patch image_project_path(project), params: editor_update_params(
        index: 0,
        target_name: "P1",
        layer: text_layer_update_params("P1", "font" => "Brand"),
        after_save_action: "download_zip"
      )
    end

    new_job = project.image_generation_jobs.order(:created_at).last
    refute_equal old_job.id, new_job.id
    refute_equal old_signature, new_job.input_signature
    assert old_job.reload.zip_file.attached?
  end

  test "enqueue failure for new zip generation does not delete previous valid cached zip" do
    project = create_project_with_tasks
    old_signature = ImageProjects::RenderInputSignature.full_zip(project)
    old_job = attach_zip_job(
      project,
      input_signature: old_signature,
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      bytes: "old-zip"
    )

    config = project.config_hash
    config["tasks"][0]["layers"][0]["text"] = "Changed before failure"
    project.update_config!(config)

    with_singleton_method_stub(ImageProjects::GenerateZipJob, :perform_later, ->(_job_id) { raise "queue unavailable" }) do
      patch image_project_path(project), params: editor_update_params(
        index: 0,
        target_name: "P1",
        layer: text_layer_update_params("P1", "text" => "Changed before failure"),
        after_save_action: "download_zip"
      )
    end

    assert_redirected_to image_project_path(project, task_index: 0)
    assert ImageGenerationJob.exists?(old_job.id)
    assert old_job.reload.zip_file.attached?
    assert_equal "old-zip", old_job.zip_file.download
  end

  test "generation job status exposes completed download url" do
    project = create_project_with_tasks
    signature = ImageProjects::RenderInputSignature.full_zip(project)
    job = attach_zip_job(
      project,
      input_signature: signature,
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      bytes: "zip-bytes"
    )

    get generation_job_status_image_project_path(project, job_id: job.id)

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal job.id, payload["id"]
    assert_equal "completed", payload["status"]
    assert_equal true, payload["input_signature_matches"]
    assert_equal true, payload["downloadable"]
    assert_equal generation_job_download_image_project_path(project, job_id: job.id), payload["download_url"]
  end

  test "generation job download redirects only when zip is ready" do
    project = create_project_with_tasks
    signature = ImageProjects::RenderInputSignature.full_zip(project)
    queued_job = project.image_generation_jobs.create!(
      status: "queued",
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      input_signature: signature
    )

    get generation_job_download_image_project_path(project, job_id: queued_job.id)
    assert_redirected_to image_project_path(project, task_index: 0)

    completed_job = attach_zip_job(
      project,
      input_signature: signature,
      generation_scope: ImageGenerationJob::ALL_TASKS_ZIP_SCOPE,
      bytes: "zip-bytes"
    )

    get generation_job_download_image_project_path(project, job_id: completed_job.id)
    assert_redirected_to rails_blob_path(completed_job.zip_file, disposition: "attachment")
  end

  test "invalid task index falls back to a valid task" do
    project = create_project_with_tasks

    get image_project_path(project, task_index: 99)

    assert_response :success
    assert_select "a.task-select-card[aria-current='page'][href='#{image_project_path(project, task_index: 1)}']" do
      assert_select ".task-title", text: "P2"
    end
    assert_includes response.body, "Selected Image: <strong>P2</strong>"

    get image_project_path(project, task_index: -2)

    assert_response :success
    assert_select "a.task-select-card[aria-current='page'][href='#{image_project_path(project, task_index: 0)}']" do
      assert_select ".task-title", text: "P1"
    end
    assert_includes response.body, "Selected Image: <strong>P1</strong>"
  end

  test "task sidebar renders task actions for each card" do
    project = create_project_with_tasks

    get image_project_path(project, task_index: 1)

    assert_response :success
    assert_select ".task-panel form[action='#{add_task_image_project_path(project)}']"
    assert_select ".task-item.active .task-actions form[action='#{move_task_image_project_path(project, task_index: 1, direction: "up")}']"
    assert_select ".task-item.active .task-actions form[action='#{move_task_image_project_path(project, task_index: 1, direction: "down")}']"
    assert_select ".task-item.active .task-actions form[action='#{duplicate_task_image_project_path(project, task_index: 1)}']"
    assert_select ".task-item.active .task-actions form[action='#{delete_task_image_project_path(project, task_index: 1)}']"
  end

  test "up down duplicate and delete actions preserve usable selection" do
    project = create_project_with_tasks([ "P1", "P2", "P3" ])

    post move_task_image_project_path(project, task_index: 1, direction: "up")
    assert_redirected_to image_project_path(project, task_index: 0)
    assert_equal [ "P2", "P1", "P3" ], project.reload.tasks.map { |task| task["targetName"] }

    post move_task_image_project_path(project, task_index: 0, direction: "down")
    assert_redirected_to image_project_path(project, task_index: 1)
    assert_equal [ "P1", "P2", "P3" ], project.reload.tasks.map { |task| task["targetName"] }

    post duplicate_task_image_project_path(project, task_index: 1)
    assert_redirected_to image_project_path(project, task_index: 2)
    assert_equal [ "P1", "P2", "P2 Copy", "P3" ], project.reload.tasks.map { |task| task["targetName"] }

    post delete_task_image_project_path(project, task_index: 2)
    assert_redirected_to image_project_path(project, task_index: 2)
    assert_equal [ "P1", "P2", "P3" ], project.reload.tasks.map { |task| task["targetName"] }
  end

  private

  def create_project_with_tasks(names = [ "P1", "P2" ])
    project = ImageProject.create!(name: "Task Selection")
    project.update_config!(
      "projectName" => "Task Selection",
      "canvasDefaults" => { "width" => 1650, "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false, "outputFormat" => "png" },
      "tasks" => names.map.with_index { |name, index| task_config(name, index) }
    )
    project
  end

  def task_config(target_name, index)
    {
      "targetName" => target_name,
      "layoutMode" => "strict",
      "canvas" => { "width" => 110 * (index + 1), "height" => 2480, "backgroundColor" => "#FAFAF0", "transparent" => false },
      "output" => { "width" => 1650, "height" => 2480, "format" => index.zero? ? "png" : "jpg" },
      "warnings" => index.zero? ? [] : [ "#{target_name} warning" ],
      "layers" => [
        {
          "id" => "layer0",
          "name" => "#{target_name} Text",
          "type" => "text",
          "text" => "#{target_name} detail copy",
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
      ]
    }
  end

  def create_project_with_image_task
    project = ImageProject.create!(name: "Image Preview Cache")
    project.update_config!(
      "projectName" => "Image Preview Cache",
      "tasks" => [
        {
          "targetName" => "P1",
          "canvas" => { "width" => 100, "height" => 100, "backgroundColor" => "#FFFFFF", "transparent" => false },
          "output" => { "width" => 100, "height" => 100, "format" => "png" },
          "layers" => [
            {
              "id" => "layer0",
              "name" => "Image",
              "type" => "image",
              "imageName" => "source",
              "width" => 100,
              "height" => 100,
              "x" => "center",
              "y" => 0,
              "fit" => "contain",
              "opacity" => 1
            }
          ]
        }
      ]
    )
    project
  end

  def attach_preview(project, task_index:, task_name:)
    preview = project.task_previews.create!(
      task_index: task_index,
      task_name: task_name,
      input_signature: ImageProjects::RenderInputSignature.preview_task(project, task_index),
      width: 1,
      height: 1,
      format: "png"
    )
    preview.file.attach(
      io: StringIO.new(Base64.decode64(PNG_1X1)),
      filename: "preview-#{task_name}.png",
      content_type: "image/png"
    )
    preview.file.blob
  end

  def attach_image_asset(project, name)
    asset = project.image_assets.create!(
      name: name,
      alias_name: ImageProjects::AssetNameNormalizer.default_alias(name),
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name),
      width: 1,
      height: 1
    )
    asset.file.attach(io: StringIO.new(Base64.decode64(PNG_1X1)), filename: name, content_type: "image/png")
    asset
  end

  def create_global_font_asset(name, bytes:)
    asset = GlobalFontAsset.create!(
      name: name,
      match_name: ImageProjects::AssetNameNormalizer.default_alias(name),
      normalized_name: ImageProjects::AssetNameNormalizer.extensionless(name)
    )
    asset.file.attach(io: StringIO.new(bytes), filename: name, content_type: "font/#{File.extname(name).delete(".")}")
    asset
  end

  def attach_zip_job(project, input_signature:, generation_scope:, bytes:)
    job = project.image_generation_jobs.create!(
      status: "completed",
      generation_scope: generation_scope,
      input_signature: input_signature,
      started_at: Time.current,
      finished_at: Time.current
    )
    job.zip_file.attach(io: StringIO.new(bytes), filename: "generated.zip", content_type: "application/zip")
    job
  end

  def create_preview_generation_job(project, status:, scope:, task_indexes:, input_signature:)
    project.preview_generation_jobs.create!(
      status: status,
      scope: scope,
      task_indexes_json: JSON.generate(task_indexes),
      task_signatures_json: JSON.generate(task_indexes.to_h { |index| [ index.to_s, ImageProjects::RenderInputSignature.preview_task(project, index) ] }),
      input_signature: input_signature,
      total_count: project.tasks.size,
      previewable_count: task_indexes.size,
      generated_count: 0,
      reused_count: 0,
      skipped_count: 0,
      failed_count: 0
    )
  end

  def preview_result_for(task_name)
    tempfile = Tempfile.new([ "preview-#{task_name}", ".png" ])
    tempfile.binmode
    tempfile.write(Base64.decode64(PNG_1X1))
    tempfile.close
    (@preview_tempfiles ||= []) << tempfile

    ImageProjects::Renderer::RenderResult.new(
      path: tempfile.path,
      filename: "#{task_name}.png",
      format: "png",
      width: 1,
      height: 1,
      warnings: [],
      errors: []
    )
  end

  def fake_zip_file(filename, bytes)
    FakeZipFile.new(filename, FakeZipBlob.new(bytes))
  end

  def editor_update_params(index:, target_name:, layer:, after_save_action:)
    params = {
      task_index: index,
      image_project: { name: "Task Selection" },
      task: {
        targetName: target_name,
        layoutMode: "strict",
        canvas: { width: (110 * (index + 1)).to_s, height: "2480", backgroundColor: "#FAFAF0", transparent: "0" },
        output: { width: "1650", height: "2480", format: index.zero? ? "png" : "jpg" }
      },
      layers: {
        "0" => layer
      }
    }
    params[:after_save_action] = after_save_action if after_save_action
    params
  end

  def text_layer_update_params(target_name, overrides = {})
    {
      "id" => "layer0",
      "name" => "#{target_name} Text",
      "type" => "text",
      "text" => "#{target_name} detail copy",
      "font" => "",
      "fontSize" => "60",
      "color" => "#1F1F1F",
      "letterSpacingRatio" => "0",
      "lineHeightRatio" => "1.2",
      "maxWidth" => "1200",
      "autoWrap" => "1",
      "bold" => "0",
      "italic" => "0",
      "x" => "center",
      "y" => "200",
      "align" => "center",
      "opacity" => "1",
      "letterSpacingMode" => "",
      "targetTextWidthRatio" => "0.78",
      "notes" => ""
    }.merge(overrides)
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
