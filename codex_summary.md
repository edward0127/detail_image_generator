Implemented the three UI/UX changes.

Files changed:
- [show.html.erb](C:/Users/edward/projects/detail_image_generator/app/views/image_projects/show.html.erb:27)
- [application.css](C:/Users/edward/projects/detail_image_generator/app/assets/stylesheets/application.css:141)
- [image_projects_controller.rb](C:/Users/edward/projects/detail_image_generator/app/controllers/image_projects_controller.rb:829)
- [image_projects_controller_task_selection_test.rb](C:/Users/edward/projects/detail_image_generator/test/controllers/image_projects_controller_task_selection_test.rb:47)
- [image_projects_controller_upload_test.rb](C:/Users/edward/projects/detail_image_generator/test/controllers/image_projects_controller_upload_test.rb:239)
- [upload_button_highlight_test.rb](C:/Users/edward/projects/detail_image_generator/test/system/upload_button_highlight_test.rb:62)

What changed:
- Success `.flash.notice` messages now get a close button and auto-dismiss after 5 seconds. Alerts/errors do not auto-dismiss. Notices with action elements are left visible.
- Project Name row button is now `Save & Preview`, submits `after_save_action=preview_current`, has no `formaction`, and stays inline with the input on desktop.
- Background Status is now a `<details>` panel. It is collapsed when idle/completed, opens for queued/running/failed jobs, and running preview/preview-all/ZIP states show an animated spinner plus progress.
- Failed preview jobs are now surfaced in the status panel so failed background status can actually expand visibly.

Tests run:
- `bundle exec rails test test\controllers\image_projects_controller_task_selection_test.rb` passed.
- `bundle exec rails test test\controllers\image_projects_controller_upload_test.rb` passed.
- `bundle exec rails test test\system\upload_button_highlight_test.rb` passed.
- `bundle exec rails test test\system\layer_editor_conditional_sections_test.rb` passed.
- `bundle exec rails test test\services\image_projects\preview_generation_runner_test.rb` passed.
- `bundle exec rails test test\services\image_projects\renderer_and_generation_test.rb` passed when run by itself.
- `bundle exec rails zeitwerk:check` passed.
- PowerShell `app\javascript` node check exited cleanly; there were no separate JS files to check.
- `git diff --check` passed aside from existing CRLF warnings.

Limitation:
- Full `bundle exec rails test` still has one order-sensitive renderer service failure: `RendererAndGenerationTest#test_batch_generation_zip_uses_P1_and_P2_target_names_with_task_formats` expected `completed` but got `completed_with_errors`. That same test passes in isolation, and the renderer service file passes by itself. The runs also emit local VIPS optional-module warnings.