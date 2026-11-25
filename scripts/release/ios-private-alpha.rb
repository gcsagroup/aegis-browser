# frozen_string_literal: true
require_relative '../../fastlane/lib/release'

# Use the standard manual-signing actions and Apple uploader without invoking
# Pipeline#package (Downloads publication) or any GitHub artifact or draft path.
module AegisPrivateAlpha
  class Request < AegisRelease::Request
    def initialize(private_root)
      @private_root = private_root
      super('ios', {profile: 'alpha', signing_mode: 'manual', destination: 'testflight',
            version: ENV.fetch('RELEASE_VERSION'), build: ENV.fetch('RELEASE_BUILD'),
            run_id: ENV.fetch('RELEASE_RUN_ID')})
    end

    def directory
      File.join(@private_root, 'package')
    end
  end

  class Pipeline < AegisRelease::Pipeline
    def initialize(private_root, fastlane)
      @private_root = private_root
      super(Request.new(private_root), fastlane)
    end

    def package_private
      source = AegisRelease.source(request.root)
      AegisRelease.require!(source['sha'] == ENV.fetch('GITHUB_SHA'), 'Source differs from workflow SHA')
      admit_source!
      team = required('AEGIS_APPLE_TEAM_ID')
      certificate = required('AEGIS_IOS_CERT_SHA1')
      AegisRelease.require!(/\A[A-Z0-9]{10}\z/.match?(team) && /\A[0-9a-fA-F]{40}\z/.match?(certificate),
                            'Expected the protected Apple team and distribution certificate')
      profiles = ios_profiles
      run('python3', File.join(request.root, 'scripts/release/safari_manifest.py'),
          File.join(request.root, 'apps/ios/SharedWebExtension'))
      inputs = File.join(@private_root, 'inputs')
      work = File.join(@private_root, 'work')
      project = File.join(work, 'apps/ios/Aegis.xcodeproj')
      firebase = File.join(work, 'apps/ios/scripts/firebase_config.py')
      firebase_args = ['--root', File.join(work, 'apps/ios/Firebase'), '--channel', 'alpha']
      stage_ios_package(work, firebase, firebase_args)
      settings = { path: project, use_automatic_signing: false, team_id: team,
                   code_sign_identity: 'Apple Distribution', build_configurations: ['Release'] }
      @fastlane.update_code_signing_settings(**settings)
      AegisRelease::IOS_TARGETS.each do |target, app_id|
        @fastlane.update_code_signing_settings(**settings, targets: [target], profile_name: profiles.fetch(app_id))
      end

      admit_source!
      run('python3', File.join(request.root, 'scripts/release/ios-durable.py'), 'export-start',
          '--version', request.version, '--build', request.build, '--profile', 'alpha')
      Dir.mkdir(request.directory, 0o700)
      name = "Aegis-alpha-#{request.version}-#{request.build}-ios.ipa"
      xcargs = [
        "MARKETING_VERSION=#{request.version}", "CURRENT_PROJECT_VERSION=#{request.build}",
        'AEGIS_FIREBASE_CHANNEL=alpha', 'AEGIS_ACCESS_RELEASE_CHANNEL=alpha',
        "AEGIS_PRIVATE_ALPHA_NODES_FILE=#{File.join(inputs, 'AegisAlphaTestNodes.json')}",
        "AEGIS_PRIVATE_TEST_NODE_FILE=#{File.join(inputs, 'AegisPrivateTestNode.vless')}",
        "AEGIS_PRIVATE_TEST_SUBSCRIPTION_FILE=#{File.join(inputs, 'AegisPrivateTestSubscription.json')}"
      ].shelljoin
      @fastlane.build_app(project: project, scheme: 'Aegis-Release', configuration: 'Release', clean: true,
                          destination: 'generic/platform=iOS', output_directory: work, output_name: name,
                          archive_path: File.join(work, 'Aegis.xcarchive'), derived_data_path: File.join(work, 'DerivedData'),
                          buildlog_path: File.join(work, 'logs'), export_method: 'app-store', suppress_xcode_output: true,
                          skip_profile_detection: true, disable_package_automatic_updates: true, xcargs: xcargs,
                          export_options: { method: 'app-store-connect', teamID: team, signingStyle: 'manual',
                                            provisioningProfiles: profiles, manageAppVersionAndBuildNumber: false,
                                            testFlightInternalTestingOnly: true })
      ipa = File.join(request.directory, name)
      File.rename(AegisRelease.file!(File.join(work, name)), ipa)
      run('python3', firebase, 'verify-ipa', *firebase_args, '--artifact', ipa)
      run('python3', File.join(request.root, 'scripts/release/verify-signed-ios.py'), ipa, request.version,
          request.build, 'alpha', '--team', team, '--certificate-sha1', certificate,
          '--profiles-json', JSON.generate(profiles), '--source-root', request.root,
          '--private-alpha-directory', inputs)
      AegisRelease::Receipt.create(request, [ipa], source,
                                  'signingMode' => 'manual', 'privateAlphaNodes' => true,
                                  'testFlightInternalTestingOnly' => true, 'deviceAcceptance' => 'not_verified')
    end

    def upload_private
      digest = ENV.fetch('RELEASE_MANIFEST_SHA256')
      AegisRelease.require!(ENV['AEGIS_PRIVATE_ALPHA_VERIFIED_MANIFEST_SHA256'] == digest,
                            'Private Alpha upload requires matching live quota verification')
      preflight_upload
      receipt = AegisRelease::Receipt.verify(request, digest)
      details = receipt.fetch('details')
      AegisRelease.require!(details.values_at('signingMode', 'privateAlphaNodes', 'testFlightInternalTestingOnly') ==
                            ['manual', true, true], 'Expected a private internal-only Alpha package')
      ipa = receipt.fetch('assets').find { |asset| asset['name'].end_with?('.ipa') }.fetch('name')
      client = store
      client.authenticate
      AegisRelease::Journal.new(request, digest).perform('apple-upload') do
        client.upload(File.join(request.directory, ipa))
      end
    end
  end

  def self.run(operation, root)
    method = { 'package' => :package_private, 'upload' => :upload_private }.fetch(operation)
    require 'fastlane'
    Fastlane.load_actions
    fastfile = Fastlane::FastFile.new
    fastfile.runner = Fastlane::Runner.new
    pipeline = Pipeline.new(root, fastfile)
    fastfile.platform(:ios) { fastfile.lane(method) { pipeline.public_send(method) } }
    fastfile.runner.execute(method, :ios)
  end
end

if $PROGRAM_NAME == __FILE__
  AegisPrivateAlpha.run(*ARGV)
end
