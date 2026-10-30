# frozen_string_literal: true
require_relative 'asc_api'

module AegisRelease
  def self.native_inputs_digest(root = ROOT)
    names = command('git', 'ls-files', '--', 'apps/ios',
                    'apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared',
                    'packages/core/src/agent/contracts/v1/agent-contract-v1.vectors.json', cwd: root).lines.map(&:strip).sort
    require!(!names.empty?, 'Missing native source inputs')
    value = Digest::SHA256.new
    names.each { |name| value.update(name + "\0" + digest(File.join(root, name)) + "\n") }
    value.hexdigest
  end

  class AppleStore
    def app_id = @app_id || @app.id

    def upload_records
      @http.collection("apps/#{app_id}/buildUploads", 'filter[cfBundleShortVersionString]' => @request.version,
                       'filter[cfBundleVersion]' => @request.build, 'filter[platform]' => 'IOS')['data']
    end

    def exact_build_document
      @http.collection('builds', 'filter[app]' => app_id, 'filter[version]' => @request.build,
                       'include' => 'preReleaseVersion,buildBetaDetail,betaGroups,betaAppReviewSubmission,appStoreVersion', 'limit' => '100')
    end

    def exact_build
      doc = exact_build_document
      versions = doc.fetch('included', []).select { |r| r['type'] == 'preReleaseVersions' }.to_h { |r| [r['id'], r['attributes']] }
      rows = doc.fetch('data').select do |r|
        train = versions[r.dig('relationships', 'preReleaseVersion', 'data', 'id')]
        r.dig('attributes', 'version') == @request.build && train && train['version'] == @request.version && train['platform'] == 'IOS'
      end
      AegisRelease.require!(rows.size <= 1, 'Ambiguous exact ASC build')
      @related = doc.fetch('included', [])
      rows.first
    end

    def processed_build
      item = exact_build
      attrs = item && item.fetch('attributes')
      AegisRelease.require!(attrs && attrs['processingState'] == 'VALID' && attrs['expired'] == false,
                            'Exact build must be VALID and unexpired; run status/wait')
      expected = @request.profile == 'alpha' ? 'INTERNAL_ONLY' : 'APP_STORE_ELIGIBLE'
      AegisRelease.require!(attrs['buildAudienceType'] == expected, 'Build audience differs from package profile')
      item
    end

    def ready_build
      item = processed_build
      AegisRelease.require!([true, false].include?(item.dig('attributes', 'usesNonExemptEncryption')), 'Complete explicit export compliance before distribution/review')
      item
    end

    def status
      item = exact_build
      uploads = upload_records
      attrs = item ? item.fetch('attributes') : {}
      detail_id = item&.dig('relationships', 'buildBetaDetail', 'data', 'id')
      detail = @related.find { |r| r['type'] == 'buildBetaDetails' && r['id'] == detail_id }&.fetch('attributes', {}) || {}
      version_id = item&.dig('relationships', 'appStoreVersion', 'data', 'id')
      version = @related.find { |r| r['type'] == 'appStoreVersions' && r['id'] == version_id }&.fetch('attributes', {}) || {}
      states = uploads.map { |r| r.dig('attributes', 'state', 'state') }.compact.uniq
      group_rows = (item&.dig('relationships', 'betaGroups', 'data') || []).map do |relation|
        group = @related.find { |r| r['type'] == 'betaGroups' && r['id'] == relation['id'] }
        testers = @http.collection("betaGroups/#{relation.fetch('id')}/betaTesters").fetch('data')
        { 'id' => relation.fetch('id'), 'name' => group&.dig('attributes', 'name'),
          'isInternalGroup' => group&.dig('attributes', 'isInternalGroup'), 'testerCount' => testers.size,
          'testerStates' => testers.group_by { |t| t.dig('attributes', 'state') || 'UNKNOWN' }.transform_values(&:size) }
      end
      { 'appId' => app_id, 'buildId' => item&.fetch('id'), 'processingState' => attrs.fetch('processingState', 'NOT_FOUND'),
        'buildAudienceType' => attrs['buildAudienceType'], 'expired' => attrs['expired'],
        'usesNonExemptEncryption' => attrs['usesNonExemptEncryption'], 'uploadState' => states.empty? ? 'NOT_FOUND' : states.join(','),
        'uploads' => uploads, 'groups' => group_rows, 'internalState' => detail['internalBuildState'], 'externalState' => detail['externalBuildState'],
        'appStoreState' => version['appStoreState'], 'appVersionState' => version['appVersionState'], 'releaseType' => version['releaseType'],
        'betaGroupIds' => item&.dig('relationships', 'betaGroups', 'data')&.map { |r| r['id'] } || [],
        'observedAt' => Time.now.utc.iso8601, 'deviceAcceptance' => 'not_verified' }
    end

    def wait_for_processing(timeout: 1800, interval: 15)
      AegisRelease.require!((1..3600).cover?(timeout) && (1..60).cover?(interval), 'Invalid wait bounds')
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        result = status
        AegisRelease.require!(!result['uploadState'].split(',').include?('FAILED') &&
                              !%w[FAILED INVALID].include?(result['processingState']), 'Apple rejected this upload/build; inspect status; do not reupload automatically')
        if result['processingState'] == 'VALID'
          processed_build
          return result
        end
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        AegisRelease.require!(remaining.positive?, 'Exact build still processing; bounded wait expired; no retry performed')
        sleep [interval, remaining].min
      end
    end

    def groups
      AegisRelease.require!(!@request.groups.empty?, 'Distribution requires explicit existing groups')
      all = @http.collection("apps/#{app_id}/betaGroups").fetch('data')
      @request.groups.map do |name|
        matches = all.select { |g| g.dig('attributes', 'name') == name }
        AegisRelease.require!(matches.size == 1, 'TestFlight group missing or ambiguous')
        group = matches.first
        AegisRelease.require!(group.dig('attributes', 'isInternalGroup') == (@request.destination == 'testflight-internal'), 'Group type differs from destination')
        group
      end
    end

    def distribute(selected = groups)
      item = ready_build
      external = @request.destination == 'testflight-external'
      # Resolve IDs before journaling. Submit external beta review only on this explicit route.
      @http.post('betaAppReviewSubmissions', 'data' => { 'type' => 'betaAppReviewSubmissions',
                 'relationships' => { 'build' => { 'data' => { 'type' => 'builds', 'id' => item.fetch('id') } } } }) if external
      @http.post("builds/#{item.fetch('id')}/relationships/betaGroups", 'data' => selected.map { |g| { 'type' => 'betaGroups', 'id' => g.fetch('id') } })
      assigned = @http.collection("builds/#{item.fetch('id')}/betaGroups").fetch('data').map { |g| g.fetch('id') }
      AegisRelease.require!((selected.map { |g| g.fetch('id') } - assigned).empty?, 'Group assignment is unconfirmed; reconcile before retry')
      testers = selected.map do |g|
        rows = @http.collection("betaGroups/#{g.fetch('id')}/betaTesters").fetch('data')
        { 'id' => g.fetch('id'), 'name' => g.dig('attributes', 'name'), 'testerCount' => rows.size,
          'testerStates' => rows.group_by { |t| t.dig('attributes', 'state') || 'UNKNOWN' }.transform_values(&:size) }
      end
      status.merge('status' => 'testflight_groups_assigned', 'groups' => testers, 'betaReviewRequested' => external,
                   'testerAvailability' => 'see internal/external state; tester state does not prove installation of this build')
    end

    def validate_metadata!(value)
      AegisRelease.require!(value.is_a?(Hash) && value.keys == ['locales'] && value['locales'].is_a?(Hash) && !value['locales'].empty?, 'Metadata requires only a nonempty locales object')
      value['locales'].each do |locale, fields|
        AegisRelease.require!(/\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}\z/.match?(locale) && fields.is_a?(Hash) && !fields.empty? &&
                              (fields.keys - %w[description whatsNew]).empty?, 'Unsupported locale or Beta metadata field')
        fields.each_value { |v| AegisRelease.require!(v.is_a?(String) && !v.strip.empty? && v.length <= 4000 && !v.include?("\0"), 'Invalid Beta metadata text') }
      end
      value
    end

    def metadata(value)
      validate_metadata!(value)
      item = processed_build
      # Fetch both collections before any write. Never send contact/listing fields.
      collections = {
        'description' => ['betaAppLocalizations', 'app', app_id, @http.collection("apps/#{app_id}/betaAppLocalizations").fetch('data')],
        'whatsNew' => ['betaBuildLocalizations', 'build', item.fetch('id'), @http.collection("builds/#{item.fetch('id')}/betaBuildLocalizations").fetch('data')]
      }
      value.fetch('locales').each do |locale, fields|
        fields.each do |field, text|
          type, relation, id, existing = collections.fetch(field)
          rows = existing.select { |r| r.dig('attributes', 'locale') == locale }
          AegisRelease.require!(rows.size <= 1, 'Ambiguous Beta localization')
          next if rows.first&.dig('attributes', field) == text
          if rows.first
            @http.patch("#{type}/#{rows.first.fetch('id')}", 'data' => { 'type' => type, 'id' => rows.first.fetch('id'), 'attributes' => { field => text } })
          else
            @http.post(type, 'data' => { 'type' => type, 'attributes' => { 'locale' => locale, field => text },
                        'relationships' => { relation => { 'data' => { 'type' => relation == 'app' ? 'apps' : 'builds', 'id' => id } } } })
          end
        end
      end
      collections.each do |field, (type, relation, id, _)|
        rows = @http.collection("#{relation == 'app' ? 'apps' : 'builds'}/#{id}/#{type}").fetch('data')
        value['locales'].each do |locale, fields|
          next unless fields.key?(field)
          AegisRelease.require!(rows.count { |r| r.dig('attributes', 'locale') == locale && r.dig('attributes', field) == fields[field] } == 1, 'Beta metadata readback mismatch; reconcile before retry')
        end
      end
      { 'status' => 'metadata_read_verified', 'buildId' => item.fetch('id'), 'locales' => value['locales'].keys, 'contactsModified' => false }
    end

    def validate_compliance!(value)
      AegisRelease.require!(value.is_a?(Hash) && value.keys.sort == %w[authorization nativeInputsSha256 sourceSha usesNonExemptEncryption].sort &&
                            [true, false].include?(value['usesNonExemptEncryption']) && value['authorization'].is_a?(String) &&
                            !value['authorization'].strip.empty? && value['authorization'].size <= 1000, 'Explicit authorized encryption declaration required')
      AegisRelease.require!(value['sourceSha'] == AegisRelease.source(@request.root).fetch('sha') &&
                            value['nativeInputsSha256'] == AegisRelease.native_inputs_digest(@request.root), 'Compliance declaration source/native scope mismatch')
      value
    end

    def compliance(value)
      validate_compliance!(value)
      item = processed_build
      current = item.dig('attributes', 'usesNonExemptEncryption')
      desired = value.fetch('usesNonExemptEncryption')
      AegisRelease.require!(current.nil? || current == desired, 'Existing encryption answer conflicts; preserve operator answer')
      if current.nil?
        @http.patch("builds/#{item.fetch('id')}", 'data' => { 'type' => 'builds', 'id' => item.fetch('id'), 'attributes' => { 'usesNonExemptEncryption' => desired } })
      end
      AegisRelease.require!(processed_build.dig('attributes', 'usesNonExemptEncryption') == desired, 'Compliance readback mismatch; reconcile before retry')
      { 'status' => 'compliance_read_verified', 'buildId' => item.fetch('id'), 'usesNonExemptEncryption' => desired }
    end
  end
end
