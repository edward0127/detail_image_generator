require "fileutils"
require "securerandom"

module ImageProjects
  class TempfileManager
    DEFAULT_STALE_AGE = 24.hours

    class << self
      def root
        Rails.root.join("tmp", "image_generator").tap { |path| FileUtils.mkdir_p(path) }
      end

      def path(prefix:, extension:, subdir: nil)
        directory = subdir.present? ? root.join(safe_segment(subdir)) : root
        FileUtils.mkdir_p(directory)

        suffix = extension.to_s.start_with?(".") ? extension.to_s : ".#{extension}"
        directory.join("#{safe_segment(prefix)}-#{SecureRandom.hex(8)}#{suffix}").to_s
      end

      def with_path(prefix:, extension:, subdir: nil)
        generated_path = path(prefix: prefix, extension: extension, subdir: subdir)
        yield generated_path
      ensure
        delete(generated_path) if generated_path.present?
      end

      def delete(path)
        return if path.blank?

        remove_path(path.to_s)
      rescue Errno::ENOENT
        nil
      rescue Errno::EACCES => error
        Rails.logger.warn("Temporary file cleanup skipped for locked file #{path}: #{error.message}")
        nil
      end

      def cleanup_stale!(older_than: DEFAULT_STALE_AGE)
        cutoff = Time.current - older_than
        Dir.glob(root.join("**", "*")).sort.reverse_each do |entry|
          next if File.directory?(entry)
          next unless File.mtime(entry) < cutoff

          delete(entry)
        end
      end

      def remove_path(path)
        File.delete(path) if File.file?(path)
      end

      private

      def safe_segment(value)
        value.to_s.strip.presence&.gsub(/[^\p{Alnum}\.\-_]+/, "_") || "tmp"
      end
    end
  end
end
