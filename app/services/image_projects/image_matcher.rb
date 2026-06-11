module ImageProjects
  class ImageMatcher
    MatchResult = Struct.new(:asset, :error, :warning, keyword_init: true) do
      def found?
        asset.present?
      end
    end

    def initialize(project)
      @project = project
    end

    def match(image_name)
      query = image_name.to_s.strip
      return MatchResult.new(error: "Image name is blank.") if query.blank?

      exact = matching_assets { |asset| AssetNameNormalizer.full(asset.name) == AssetNameNormalizer.full(query) }
      return result_from_candidates(query, exact, exact: true) if exact.any?

      extensionless = matching_assets do |asset|
        AssetNameNormalizer.extensionless(asset.name) == AssetNameNormalizer.extensionless(query)
      end
      return result_from_candidates(query, extensionless) if extensionless.any?

      alias_match = matching_assets { |asset| AssetNameNormalizer.full(alias_name_for(asset)) == AssetNameNormalizer.full(query) }
      return result_from_candidates(query, alias_match) if alias_match.any?

      loose_query = AssetNameNormalizer.loose(query)
      loose = matching_assets { |asset| loose_names_for(asset).include?(loose_query) }
      return result_from_candidates(query, loose, loose: true) if loose.any?

      MatchResult.new(error: "Image '#{query}' was not found in uploaded image assets. Match the uploaded filename, extensionless filename, or image alias.")
    end

    private

    attr_reader :project

    def assets
      @assets ||= project.image_assets.to_a
    end

    def matching_assets(&block)
      assets.select(&block)
    end

    def result_from_candidates(query, candidates, exact: false, loose: false)
      selected = candidates.min_by { |asset| match_distance(query, asset.name) }
      warnings = []
      warnings << "Multiple images matched '#{query}'; using '#{selected.name}'." if candidates.size > 1
      warnings << "Image '#{query}' matched loosely to '#{selected.name}'." if loose

      MatchResult.new(asset: selected, warning: warnings.presence&.join(" "))
    end

    def loose_names_for(asset)
      [ asset.name, asset.normalized_name, alias_name_for(asset) ].compact_blank.map { |name| AssetNameNormalizer.loose(name) }.uniq
    end

    def alias_name_for(asset)
      asset.respond_to?(:alias_name) ? asset.alias_name : nil
    end

    def match_distance(query, asset_name)
      (AssetNameNormalizer.full(asset_name).length - AssetNameNormalizer.full(query).length).abs
    end
  end
end
