# frozen_string_literal: true
require_relative 'ios_status'

module AegisRelease
  # Candidate-only test adapter. It cannot distribute, change metadata, or submit review.
  # Production Pipeline admission remains current-main-only.
  class CloudPocStore
    Identity = Struct.new(:version, :build, :profile, keyword_init: true)

    def initialize(fastlane, root: ROOT)
      @fastlane, @root = fastlane, root
    end

    def admission!
      AegisRelease.require!(ENV['GITHUB_ACTIONS'] == 'true' && ENV['RUNNER_ENVIRONMENT'] == 'github-hosted' &&
                            ENV['RUNNER_OS'] == 'macOS', 'Cloud PoC upload only runs on the admitted hosted runner')
      AegisRelease.command('node', File.join(@root, 'scripts/ci/ios-cloud-poc-admission.mjs'), cwd: @root)
      current = AegisRelease.source(@root)
      AegisRelease.require!(current['sha'] == ENV['GITHUB_SHA'], 'Cloud PoC checkout differs from admitted source')
      current.reject { |key, _| key == 'dirty' }
    end

    def identity
      version, build = ENV.values_at('POC_VERSION', 'POC_BUILD')
      AegisRelease.require!(/\A\d+\.\d+(?:\.\d+)?\z/.match?(version.to_s) && /\A[1-9]\d{0,9}\z/.match?(build.to_s), 'Invalid cloud PoC version/build')
      Identity.new(version: version, build: build, profile: 'beta')
    end

    def run_id
      value = ENV.fetch('POC_RUN_ID')
      AegisRelease.require!(/\A[A-Za-z0-9][A-Za-z0-9_-]{0,79}\z/.match?(value), 'Invalid cloud PoC run ID')
      value
    end

    def directory = File.join(@root, '.artifacts/cloud-signing-poc', run_id)
    def state_directory = File.join(@root, '.artifacts/cloud-signing-state', run_id)

    def store
      @store ||= AppleStore.new(identity, @fastlane, admission: method(:admission!)).tap(&:authenticate)
    end

    def state_file(name)
      AegisRelease.real_path!(state_directory)
      FileUtils.mkdir_p(state_directory)
      File.join(state_directory, name)
    end

    def preflight
      source = admission!
      before = CloudReservations.preflight(store, identity, source)
      AegisRelease.write_new(state_file('preflight.json'), 'source' => source, 'version' => identity.version,
                            'build' => identity.build, 'cloudExportPreflight' => before, 'uploadAttempted' => false)
      before
    end

    def verify_package(source)
      receipt_path = File.join(directory, 'poc-receipt.json')
      receipt = JSON.parse(File.read(AegisRelease.file!(receipt_path)))
      AegisRelease.require!(receipt['source'] == source && receipt['status'] == 'ipa_verified' &&
                            receipt['runtime'] == 'github-hosted' && receipt['signingMode'] == 'cloud' &&
                            receipt.values_at('version', 'build', 'profile') == [identity.version, identity.build, 'beta'] &&
                            receipt['runId'] == ENV['GITHUB_RUN_ID'] && receipt['runAttempt'] == ENV['GITHUB_RUN_ATTEMPT'] &&
                            receipt['distributionP12Imported'] == false && receipt['keychainRestored'] == true &&
                            receipt['cleanRunnerDistributionIdentityAbsent'] == true &&
                            receipt['distributionIdentityAbsentAfterExport'] == true && !receipt.key?('reusedArchiveFrom'),
                            'Fresh hosted cloud package evidence differs from the admitted request')
      assets = receipt.fetch('assets')
      AegisRelease.require!(assets.is_a?(Array) && assets.size == 4 && assets.map { |a| a['name'] }.uniq.size == 4 &&
                            %w[signature-verification.json dsym-verification.json].all? { |name| assets.any? { |a| a['name'] == name } }, 'Incomplete cloud assets')
      assets.each do |asset|
        name = asset.fetch('name')
        AegisRelease.require!(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/.match?(name) && !name.include?('..'), 'Unsafe cloud asset')
        path = File.join(directory, name)
        AegisRelease.require!(AegisRelease.digest(path) == asset['sha256'] && File.size(path) == asset['size'], 'Cloud asset changed')
      end
      ipa = File.join(directory, receipt.fetch('ipa'))
      AegisRelease.require!(assets.count { |a| a['name'].end_with?('.ipa') } == 1 &&
                            assets.any? { |a| a['name'] == receipt['ipa'] } &&
                            assets.any? { |a| a['name'] == receipt['dsym'] && a['name'].end_with?('.dSYM.zip') }, 'IPA/dSYM membership differs')
      AegisRelease.command('python3', File.join(@root, 'scripts/release/verify-signed-ios.py'), ipa,
                           identity.version, identity.build, 'beta', '--signing-mode', 'cloud', '--team', receipt.fetch('team'),
                           '--expected-verification', File.join(directory, 'signature-verification.json'), '--source-root', @root, cwd: @root)
      [receipt, ipa]
    end

    def upload_and_wait
      source = admission!
      AegisRelease.require!(ENV['GITHUB_RUN_ATTEMPT'] == '1' && ENV['POC_UPLOAD'] == 'true', 'Cloud test upload requires explicit first-attempt selection; reruns are read-only reconciliation')
      receipt, ipa = verify_package(source)
      started = state_file('upload-started.json')
      AegisRelease.require!(!File.exist?(started) && !File.exist?(state_file('upload-result.json')), 'Upload already attempted; reconcile ASC instead of retrying')
      before = JSON.parse(File.read(AegisRelease.file!(state_file('preflight.json')))).fetch('cloudExportPreflight')
      reservation = CloudReservations.capture(store, identity, source, before)
      reservation_path = state_file('cloud-upload-reservation.json')
      AegisRelease.write_new(reservation_path, reservation)
      intent = {'source' => source, 'version' => identity.version, 'build' => identity.build,
                'ipaSha256' => receipt.fetch('ipaSha256'), 'dsymSha256' => receipt.fetch('dsymSha256'),
                'packageReceiptSha256' => AegisRelease.digest(File.join(directory, 'poc-receipt.json')),
                'cloudReservationSha256' => AegisRelease.digest(reservation_path),
                'outcome' => 'unknown', 'reviewSubmitted' => false}
      AegisRelease.write_new(started, intent)
      result = store.upload(ipa, cloud_reservations: reservation, source: source)
      AegisRelease.write_new(state_file('upload-result.json'), intent.merge('result' => result))
      processed = store.wait_for_processing(timeout: 1800, interval: 15)
      AegisRelease.write_new(state_file('processing-result.json'), intent.merge('result' => processed, 'outcome' => 'processing_valid', 'deviceAcceptance' => 'not_verified'))
      processed
    end
  end
end
