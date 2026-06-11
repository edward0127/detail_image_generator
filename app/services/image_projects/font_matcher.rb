module ImageProjects
  class FontMatcher
    MatchResult = Struct.new(:asset, :warning, :fallback, keyword_init: true) do
      def found?
        asset.present?
      end

      def fallback?
        fallback == true
      end
    end

    def initialize(project)
      @project = project
    end

    def match(font_name)
      query = font_name.to_s.strip
      return fallback_result("No font specified; using browser fallback font.") if query.blank?

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

      fallback_result("Font \"#{query}\" was not uploaded. A fallback font was used, so the generated image may not visually match the expected design.")
    end

    private

    attr_reader :project

    def assets
      @assets ||= project.font_assets.to_a
    end

    def matching_assets(&block)
      assets.select(&block)
    end

    def result_from_candidates(query, candidates, exact: false, loose: false)
      selected = candidates.min_by { |asset| match_distance(query, asset.name) }
      warnings = []
      warnings << "Multiple fonts matched '#{query}'; using '#{selected.name}'." if candidates.size > 1
      warnings << "Font '#{query}' matched loosely to '#{selected.name}'." if loose
      warnings << "Font '#{query}' matched uploaded font '#{selected.name}'." if !exact && !loose && AssetNameNormalizer.full(query) != AssetNameNormalizer.full(selected.name)

      MatchResult.new(asset: selected, warning: warnings.presence&.join(" "))
    end

    def fallback_result(warning)
      MatchResult.new(warning: warning, fallback: true)
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
