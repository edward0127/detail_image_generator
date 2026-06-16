Implemented the double-confirmation delete flow.

**Changed Files**
- [config/routes.rb](C:/Users/edward/projects/detail_image_generator/config/routes.rb:12)
- [image_projects_controller.rb](C:/Users/edward/projects/detail_image_generator/app/controllers/image_projects_controller.rb:27)
- [delete_confirmation.html.erb](C:/Users/edward/projects/detail_image_generator/app/views/image_projects/delete_confirmation.html.erb:1)
- [index.html.erb](C:/Users/edward/projects/detail_image_generator/app/views/image_projects/index.html.erb:30)
- [show.html.erb](C:/Users/edward/projects/detail_image_generator/app/views/image_projects/show.html.erb:534)
- [delete_confirmation_controller.js](C:/Users/edward/projects/detail_image_generator/app/javascript/controllers/delete_confirmation_controller.js:3)
- [application.css](C:/Users/edward/projects/detail_image_generator/app/assets/stylesheets/application.css:1003)
- [image_projects_controller_upload_test.rb](C:/Users/edward/projects/detail_image_generator/test/controllers/image_projects_controller_upload_test.rb:701)
- [project_deletion_confirmation_test.rb](C:/Users/edward/projects/detail_image_generator/test/system/project_deletion_confirmation_test.rb:4)

**What Changed**
- Added `GET /image_projects/:id/delete_confirmation`.
- Index and show-page Danger Zone delete actions now open the confirmation page instead of sending `DELETE`.
- Confirmation page shows the requested deletion summary table and warning.
- Final delete requires typing the exact project name.
- `DELETE /image_projects/:id` is server-side protected and rejects missing/wrong confirmation names.
- Deletion still goes through `ImageProjects::ProjectDestroyer`.

**Tests Added/Updated**
- Added system test for index Delete -> confirmation -> Cancel keeps project.
- Updated controller tests for summary display, missing/wrong confirmation rejection, and valid confirmed deletion.
- Existing destroyer cleanup tests still pass.

**Commands Run**
- `bundle exec rails test test/controllers/image_projects_controller_upload_test.rb` passed: 36 runs, 391 assertions.
- `bundle exec rails test test/system/project_deletion_confirmation_test.rb` passed: 1 run, 9 assertions.
- `bundle exec rails test test/services/image_projects/project_destroyer_test.rb` passed: 2 runs, 23 assertions.
- `bundle exec rails test` passed: 152 runs, 1050 assertions.
- `bundle exec rails zeitwerk:check` passed.
- `Get-ChildItem -Path app\javascript -Filter *.js -Recurse | ForEach-Object { node --check $_.FullName }` passed.
- `git diff --check` passed, with only existing CRLF normalization warnings.

**Limitations**
- Test runs emit existing VIPS warnings about optional image modules missing, but all tests passed.
- I did not change Docker/Nginx/deployment and did not leave a Rails server running. Capybara briefly started Puma for the system test only.