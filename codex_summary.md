Implemented both parts.

**Files Changed**
- [inline_text_parser.rb](C:/Users/edward/projects/detail_image_generator/app/services/image_projects/inline_text_parser.rb)
- [renderer.rb](C:/Users/edward/projects/detail_image_generator/app/services/image_projects/renderer.rb)
- [excel_parsers.rb](C:/Users/edward/projects/detail_image_generator/app/services/image_projects/excel_parsers.rb)
- [image_projects_controller.rb](C:/Users/edward/projects/detail_image_generator/app/controllers/image_projects_controller.rb)
- [show.html.erb](C:/Users/edward/projects/detail_image_generator/app/views/image_projects/show.html.erb)
- [application.css](C:/Users/edward/projects/detail_image_generator/app/assets/stylesheets/application.css)
- Related parser, renderer, importer, controller, and system tests.

**Behavior**
- `**bold**` and `*italic*` are now supported in the existing `layer["text"]` field.
- `**DESIGN** HIGHLIGHTS` renders in one text layer with only `DESIGN` bold.
- User HTML is escaped, not rendered.
- Whole-layer Bold and Italic still work.
- Centered short titles with inline styles still use the deterministic `.tracked-grapheme` path; markup characters are stripped from layout measurement and `aria-label`.
- Excel notes like `其中 DESIGN 这个单词加粗` now convert text to `**DESIGN** HIGHLIGHTS` without setting whole-layer bold.
- Editor save, preview autosave, and ZIP autosave preserve inline markup.
- Blank/invalid projects now disable Preview and Download with helper text.
- Server-side guards reject preview/download/generate actions for empty projects or missing required source images.

**Validation**
Passed:
- `bundle exec rails test test/services/image_projects/inline_text_parser_test.rb`
- `bundle exec rails test test/services/image_projects/renderer_html_test.rb`
- `bundle exec rails test test/services/image_projects/renderer_and_generation_test.rb`
- `bundle exec rails test test/services/image_projects/excel_importer_test.rb`
- `bundle exec rails test test/controllers/image_projects_controller_upload_test.rb`
- `bundle exec rails test test/controllers/image_projects_controller_task_selection_test.rb`
- `bundle exec rails test test/system/layer_editor_conditional_sections_test.rb`
- `bundle exec rails test` → `136 runs, 929 assertions, 0 failures, 0 errors`
- `bundle exec rails zeitwerk:check` → `All is good!`

No JavaScript toolbar was added, so Node checks were not applicable. No migration was added.

Remaining limitation: the inline parser intentionally supports only simple paired `**...**`, `*...*`, and `***...***`; malformed or unmatched markers render literally.