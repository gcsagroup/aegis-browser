# frozen_string_literal: true

module AegisRelease
  # Xcode cloud export reserves an empty buildUpload without uploading the IPA.
  # Only reservations created after our own empty preflight may cross upload guards.
  module CloudReservations
    def self.identity(request, source)
      AegisRelease.require!(source.is_a?(Hash) && source['dirty'] != true &&
                            %w[sha tree].all? { |key| /\A[0-9a-f]{40}\z/.match?(source[key].to_s) }, 'Exact clean cloud reservation source required')
      {'source' => source.reject { |key, _| key == 'dirty' }, 'version' => request.version, 'build' => request.build}
    end

    def self.preflight(store, request, source)
      state = store.status
      AegisRelease.require!(state['processingState'] == 'NOT_FOUND' && state['uploadState'] == 'NOT_FOUND' && state['uploads'] == [],
                            'Cloud export requires an unused version/build before archive')
      identity(request, source).merge('absentBeforeExport' => true, 'observedAt' => state.fetch('observedAt'))
    end

    def self.validate_identity!(proof, request, source)
      AegisRelease.require!(proof.is_a?(Hash) && proof['absentBeforeExport'] == true &&
                            identity(request, source).all? { |key, value| proof[key] == value }, 'Cloud reservation provenance differs')
      Time.iso8601(proof.fetch('observedAt'))
    end

    def self.empty!(store, record, request)
      attributes = record.fetch('attributes')
      id = record.fetch('id')
      AegisRelease.require!(record['type'] == 'buildUploads' && /\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/.match?(id) &&
                            attributes.values_at('cfBundleShortVersionString', 'cfBundleVersion', 'platform') == [request.version, request.build, 'IOS'] &&
                            attributes.dig('state', 'state') == 'AWAITING_UPLOAD' && attributes.dig('state', 'errors') == [] &&
                            attributes.key?('uploadedDate') && attributes['uploadedDate'].nil? &&
                            store.upload_files(id).empty?, 'Cloud export reservation contains upload activity or differs from the exact build')
      {'id' => id, 'createdDate' => attributes.fetch('createdDate')}
    end

    def self.capture(store, request, source, before)
      started = validate_identity!(before, request, source)
      AegisRelease.require!(store.exact_build.nil?, 'Build appeared during cloud export')
      records = store.upload_records
      AegisRelease.require!(records.size <= 1, 'Ambiguous cloud export reservations')
      reservations = records.map { |record| empty!(store, record, request) }
      reservations.each do |record|
        created = Time.iso8601(record.fetch('createdDate'))
        AegisRelease.require!(created >= started - 5 && created <= Time.now + 5, 'Cloud reservation predates this export')
      end
      before.merge('reservations' => reservations, 'capturedAt' => Time.now.utc.iso8601)
    end

    def self.verify!(store, request, source, proof)
      validate_identity!(proof, request, source)
      expected = proof.fetch('reservations')
      AegisRelease.require!(expected.is_a?(Array) && expected.size <= 1 && store.exact_build.nil?, 'Invalid cloud upload reservation receipt')
      actual = store.upload_records.map { |record| empty!(store, record, request) }
      AegisRelease.require!(actual == expected, 'Upload reservations changed after package verification')
      true
    end
  end
end
