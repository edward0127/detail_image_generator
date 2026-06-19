Implemented.

- Added reusable Rails `<time>` rendering in [application_helper.rb](C:/Users/edward/projects/detail_image_generator/app/helpers/application_helper.rb:4), with UTC ISO8601 `datetime`, `data-local-time`, and UTC tooltip fallback.
- Added browser-local formatting in [application.js](C:/Users/edward/projects/detail_image_generator/app/javascript/application.js:3) using `Intl.DateTimeFormat`.
- Applied local-time rendering to the project index, delete/clear summaries, and ZIP “Started” time, including AJAX/polling updates.
- Refactored the ZIP status header in [show.html.erb](C:/Users/edward/projects/detail_image_generator/app/views/image_projects/show.html.erb:175) and [application.css](C:/Users/edward/projects/detail_image_generator/app/assets/stylesheets/application.css:563) so the fixed ZIP badge, wrapping title, and right-aligned progress counter do not crowd or overlap.

No generation logic, job behavior, cache signatures, persisted timestamps, or download behavior was changed.

Verification run:

- `bundle exec rails test test\controllers\image_projects_controller_upload_test.rb` passed: 44 runs, 598 assertions
- `bundle exec rails test test\controllers\image_projects_controller_task_selection_test.rb` passed: 41 runs, 438 assertions
- `bundle exec rails test test\system\upload_button_highlight_test.rb` passed: 13 runs, 84 assertions
- `node --check app\javascript\application.js` passed
- `git diff --check` passed

The Rails test runs still emit existing VIPS optional-module warnings, but all targeted tests pass.