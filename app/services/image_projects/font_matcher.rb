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

      project_match = match_assets(project_assets, query)
      return project_match if project_match

      global_match = match_assets(global_assets, query)
      return global_match if global_match

      fallback_result("Font \"#{query}\" was not uploaded. A fallback font was used, so the generated image may not visually match the expected design.")
    end

    private

    attr_reader :project

    def project_assets
      @project_assets ||= usable_assets(project.font_assets.to_a)
    end

    def global_assets
      @global_assets ||= usable_assets(GlobalFontAsset.all.to_a)
    end

    def usable_assets(assets)
      assets.select { |asset| asset.respond_to?(:file) && asset.file.attached? }
    end

    def match_assets(assets, query)
      exact = matching_assets(assets) { |asset| AssetNameNormalizer.full(asset.name) == AssetNameNormalizer.full(query) }
      return result_from_candidates(query, exact, exact: true) if exact.any?

      extensionless = matching_assets(assets) do |asset|
        extensionless_names_for(asset).include?(AssetNameNormalizer.extensionless(query))
      end
      return result_from_candidates(query, extensionless) if extensionless.any?

      alias_match = matching_assets(assets) { |asset| AssetNameNormalizer.full(match_name_for(asset)) == AssetNameNormalizer.full(query) }
      return result_from_candidates(query, alias_match) if alias_match.any?

      loose_query = AssetNameNormalizer.loose(query)
      loose = matching_assets(assets) { |asset| loose_names_for(asset).include?(loose_query) }
      return result_from_candidates(query, loose, loose: true) if loose.any?

      nil
    end

    def matching_assets(assets, &block)
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
      [ asset.name, asset.normalized_name, match_name_for(asset) ].compact_blank.map { |name| AssetNameNormalizer.loose(name) }.uniq
    end

    def extensionless_names_for(asset)
      [ AssetNameNormalizer.extensionless(asset.name), asset.normalized_name ].compact_blank.map { |name| AssetNameNormalizer.full(name) }.uniq
    end

    def match_name_for(asset)
      return asset.match_name if asset.respond_to?(:match_name)
      return asset.alias_name if asset.respond_to?(:alias_name)

      nil
    end

    def match_distance(query, asset_name)
      (AssetNameNormalizer.full(asset_name).length - AssetNameNormalizer.full(query).length).abs
    end
  end
end
