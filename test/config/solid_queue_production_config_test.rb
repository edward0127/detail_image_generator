require "test_helper"

class SolidQueueProductionConfigTest < ActiveSupport::TestCase
  test "production config uses solid queue adapter and queue database" do
    production_config = Rails.root.join("config/environments/production.rb").read

    assert_includes production_config, "config.active_job.queue_adapter = :solid_queue"
    assert_includes production_config, "config.solid_queue.connects_to = { database: { writing: :queue } }"
  end

  test "solid queue queue config and migrations exist" do
    queue_config = Rails.root.join("config/queue.yml")
    queue_migration = Rails.root.join("db/queue_migrate/20260617000000_create_solid_queue_tables.rb")

    assert queue_config.exist?
    assert_includes queue_config.read, "queues: [ image_generation, default ]"
    assert_includes queue_config.read, "threads: 1"
    assert queue_migration.exist?
    assert_includes queue_migration.read, "solid_queue_jobs"
    assert_includes queue_migration.read, "solid_queue_ready_executions"
  end

  test "docker and compose enable puma solid queue and process reaping" do
    dockerfile = Rails.root.join("Dockerfile").read
    env_example = Rails.root.join(".env.prod.example").read
    compose = Rails.root.join("docker-compose.yml").read
    puma_config = Rails.root.join("config/puma.rb").read

    assert_includes dockerfile, 'SOLID_QUEUE_IN_PUMA="true"'
    assert_includes env_example, "SOLID_QUEUE_IN_PUMA=true"
    assert_includes puma_config, "plugin :solid_queue if ENV[\"SOLID_QUEUE_IN_PUMA\"]"
    assert_includes compose, "init: true"
  end

  test "production queue database defaults to data volume path" do
    database_config = Rails.root.join("config/database.yml").read

    assert_includes database_config, 'ENV.fetch("SQLITE_QUEUE_DATABASE", "/data/production_queue.sqlite3")'
    assert_includes database_config, "migrations_paths: db/queue_migrate"
  end
end
