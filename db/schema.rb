# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_16_000000) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "font_assets", force: :cascade do |t|
    t.string "alias_name", default: "", null: false
    t.datetime "created_at", null: false
    t.integer "image_project_id", null: false
    t.string "name", null: false
    t.string "normalized_name", null: false
    t.datetime "updated_at", null: false
    t.index ["image_project_id", "alias_name"], name: "index_font_assets_on_image_project_id_and_alias_name"
    t.index ["image_project_id", "normalized_name"], name: "index_font_assets_on_image_project_id_and_normalized_name"
    t.index ["image_project_id"], name: "index_font_assets_on_image_project_id"
  end

  create_table "generated_images", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_messages", default: "[]", null: false
    t.string "format", null: false
    t.integer "height"
    t.integer "image_generation_job_id", null: false
    t.string "target_name", null: false
    t.datetime "updated_at", null: false
    t.text "warnings", default: "[]", null: false
    t.integer "width"
    t.index ["image_generation_job_id"], name: "index_generated_images_on_image_generation_job_id"
  end

  create_table "global_font_assets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "match_name", default: "", null: false
    t.string "name", null: false
    t.string "normalized_name", null: false
    t.datetime "updated_at", null: false
    t.index ["match_name"], name: "index_global_font_assets_on_match_name"
    t.index ["normalized_name"], name: "index_global_font_assets_on_normalized_name"
  end

  create_table "image_assets", force: :cascade do |t|
    t.string "alias_name", default: "", null: false
    t.datetime "created_at", null: false
    t.integer "height"
    t.integer "image_project_id", null: false
    t.string "name", null: false
    t.string "normalized_name", null: false
    t.datetime "updated_at", null: false
    t.integer "width"
    t.index ["image_project_id", "alias_name"], name: "index_image_assets_on_image_project_id_and_alias_name"
    t.index ["image_project_id", "normalized_name"], name: "index_image_assets_on_image_project_id_and_normalized_name"
    t.index ["image_project_id"], name: "index_image_assets_on_image_project_id"
  end

  create_table "image_generation_jobs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_messages", default: "[]", null: false
    t.datetime "finished_at"
    t.integer "image_project_id", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.text "warnings", default: "[]", null: false
    t.index ["image_project_id"], name: "index_image_generation_jobs_on_image_project_id"
  end

  create_table "image_projects", force: :cascade do |t|
    t.text "config_json", default: "{}", null: false
    t.datetime "created_at", null: false
    t.text "last_error"
    t.string "name", null: false
    t.integer "preview_task_index"
    t.string "preview_task_name"
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "font_assets", "image_projects"
  add_foreign_key "generated_images", "image_generation_jobs"
  add_foreign_key "image_assets", "image_projects"
  add_foreign_key "image_generation_jobs", "image_projects"
end
