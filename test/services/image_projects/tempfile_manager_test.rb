require "test_helper"

class ImageProjects::TempfileManagerTest < ActiveSupport::TestCase
  test "active storage analyzers are disabled because app manages image metadata directly" do
    assert_empty ActiveStorage.analyzers
  end

  test "with_path creates a closed path under the app temp directory and cleans it up" do
    yielded_path = nil

    ImageProjects::TempfileManager.with_path(prefix: "sample", extension: ".txt", subdir: "tests") do |path|
      yielded_path = path
      assert path.start_with?(Rails.root.join("tmp", "image_generator").to_s)
      File.write(path, "temporary")
      assert_equal "temporary", File.read(path)
    end

    refute File.exist?(yielded_path)
  end

  test "cleanup-only Windows access errors are logged and not raised" do
    path = ImageProjects::TempfileManager.path(prefix: "locked", extension: ".tmp", subdir: "tests")
    File.write(path, "locked")
    calls = 0
    original_remove_path = ImageProjects::TempfileManager.method(:remove_path)

    ImageProjects::TempfileManager.define_singleton_method(:remove_path) do |_path|
      calls += 1
      raise Errno::EACCES, "locked"
    end
    begin
      ImageProjects::TempfileManager.delete(path)
    ensure
      ImageProjects::TempfileManager.define_singleton_method(:remove_path, original_remove_path)
    end

    assert_equal 1, calls
  ensure
    File.delete(path) if path.present? && File.exist?(path)
  end
end
