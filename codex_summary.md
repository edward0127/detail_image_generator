Implemented.

Changed [index.html.erb](C:/Users/edward/projects/detail_image_generator/app/views/image_projects/index.html.erb:30) to wrap `View` and `Delete` in `.project-actions`, and updated [application.css](C:/Users/edward/projects/detail_image_generator/app/assets/stylesheets/application.css:1465) so the Actions cell:

- keeps the buttons on one line with `flex-wrap: nowrap`
- right-aligns them with `justify-content: flex-end`
- keeps an `8px` gap
- reserves enough cell width and prevents button shrink/cramping

I also updated the existing controller test at [image_projects_controller_upload_test.rb](C:/Users/edward/projects/detail_image_generator/test/controllers/image_projects_controller_upload_test.rb:907) to assert the wrapper and action order.

Validation:
- `ruby bin\rails test test\controllers\image_projects_controller_upload_test.rb` passed: `44 runs, 617 assertions, 0 failures`
- Existing local server at `http://127.0.0.1:3000/image_projects` returns `200` and includes the new `project-actions` wrapper
- Delete link destination/classes were preserved; delete confirmation flow was not changed

Note: `codex_summary.md` is already modified in the working tree; I did not edit it.