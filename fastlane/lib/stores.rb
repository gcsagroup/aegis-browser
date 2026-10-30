# frozen_string_literal: true

module AegisRelease
  # A process lock plus an immutable intent survives a lost network response. Never
  # retry a possibly completed mutation just because the client did not see success.
  class Journal
    def initialize(request, digest)
      @request, @digest = request, digest
    end

    def perform(operation, parameters = {})
      root = @request.directory
      lock_path = AegisRelease.real_path!(File.join(root, '.store.lock'))
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        AegisRelease.require!(lock.flock(File::LOCK_EX | File::LOCK_NB), 'Another store stage is running for this package')
        Receipt.verify(@request, @digest)
        intent = @request.identity.merge('manifestSha256' => @digest, 'operation' => operation, 'parameters' => parameters)
        started = File.join(root, "#{operation}-started.json")
        finished = File.join(root, "#{operation}-result.json")
        if File.exist?(finished)
          result = JSON.parse(File.read(AegisRelease.file!(finished)))
          AegisRelease.require!(result['intent'] == intent, 'Completed stage has different parameters; inspect status before changing destinations')
          return result.fetch('result')
        end
        AegisRelease.require!(!File.exist?(started), 'Earlier store stage has an unknown outcome. Run status and reconcile with the store; automatic retries are disabled')
        AegisRelease.write_new(started, intent.merge('startedAt' => Time.now.utc.iso8601, 'outcome' => 'unknown'))
        result = yield
        AegisRelease.write_new(finished, 'intent' => intent, 'result' => result, 'completedAt' => Time.now.utc.iso8601)
        result
      end
    end
  end

  class AppleStore
    def initialize(request, fastlane, api: nil, app_id: nil)
      @request, @fastlane, @http, @app_id = request, fastlane, api, app_id
    end

    def authenticate
      require 'spaceship'
      key = { key_id: ENV.fetch('AEGIS_ASC_KEY_ID'), issuer_id: ENV.fetch('AEGIS_ASC_ISSUER_ID') }
      if ENV['AEGIS_ASC_KEY_PATH'].to_s != ''
        path = AegisRelease.file!(File.realpath(ENV.fetch('AEGIS_ASC_KEY_PATH')))
        AegisRelease.require!((File.stat(path).mode & 0o077).zero?, 'ASC key file must be private (mode 600)')
        key[:key_filepath] = path
      else
        key.merge!(key_content: ENV.fetch('AEGIS_ASC_KEY_BASE64'), is_key_content_base64: true)
      end
      @api_key = @fastlane.app_store_connect_api_key(**key)
      @app = Spaceship::ConnectAPI::App.find(APP_ID)
      AegisRelease.require!(@app && @app.bundle_id == APP_ID, 'ASC application not found for the exact bundle ID')
      @http ||= AscApi.new(token: Spaceship::ConnectAPI.token)
    end

    def upload(ipa)
      AegisRelease.require!(exact_build.nil? && upload_records.empty?, 'ASC already contains this build or upload; inspect status instead of uploading again')
      @fastlane.upload_to_testflight(api_key: @api_key, app_identifier: APP_ID, ipa: ipa,
                                    skip_submission: true, skip_waiting_for_build_processing: true,
                                    distribute_external: false)
      { 'status' => 'uploaded_processing_unverified', 'appId' => app_id, 'reviewSubmitted' => false }
    end

    def submit
      ready_build
      # Store listing, privacy, review contact and compliance are operator-owned.
      # Do not fabricate answers, change version trains or overwrite listing data.
      version = @app.get_edit_app_store_version(platform: 'IOS')
      AegisRelease.require!(version && version.version_string == @request.version, 'Prepare this exact App Store version and its metadata in ASC before submitting')
      AegisRelease.require!(!@app.get_in_progress_review_submission(platform: 'IOS'), 'Another App Review is already in progress')
      # deliver skips release-type changes when skip_metadata is true.
      version.update(attributes: { releaseType: 'MANUAL' }) unless version.release_type == 'MANUAL'
      @fastlane.upload_to_app_store(api_key: @api_key, app_identifier: APP_ID,
                                   app_version: @request.version, build_number: @request.build,
                                   skip_binary_upload: true, skip_metadata: true, skip_screenshots: true,
                                   submit_for_review: true, automatic_release: false, force: true,
                                   run_precheck_before_submit: true, precheck_include_in_app_purchases: false)
      result = status
      AegisRelease.require!(%w[WAITING_FOR_REVIEW IN_REVIEW].include?(result['appVersionState']) ||
                            %w[WAITING_FOR_REVIEW IN_REVIEW].include?(result['appStoreState']),
                            'App Review submission has not been confirmed; inspect ASC')
      AegisRelease.require!(result['releaseType'] == 'MANUAL', 'App Store manual release policy was not confirmed')
      result.merge('status' => 'app_review_submitted')
    end
  end

end
