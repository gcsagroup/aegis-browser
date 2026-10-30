# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/release'

class ReleaseFixture < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir('aegis-release-test-'))
    write('.gitignore', ".artifacts/\n")
    write('apps/ios/project.yml', "MARKETING_VERSION: 3.2\nCURRENT_PROJECT_VERSION: 69\n")
    git('init', '-q')
    git('config', 'user.name', 'Fixture')
    git('config', 'user.email', 'fixture@example.invalid')
    git('add', '.')
    git('commit', '-qm', 'fixture')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write(relative, value)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, value)
    path
  end

  def git(*args)
    AegisRelease.command('git', *args, cwd: @root)
  end

  def request(platform = 'ios', **options)
    AegisRelease::Request.new(platform, {profile: 'release'}.merge(options), root: @root)
  end

  def package(platform = 'ios', **options)
    req = request(platform, **options)
    FileUtils.mkdir_p(req.directory)
    extension = req.format
    path = File.join(req.directory, "Aegis.#{extension}")
    File.write(path, 'fixture, not a real package')
    sha = AegisRelease::Receipt.create(req, [path], AegisRelease.source(@root), 'signing' => 'fixture', 'appleTeamId' => 'ABCDEFGHIJ', 'certificateSha1' => 'A' * 40,
                                      'provisioningProfiles' => AegisRelease::IOS_TARGETS.values.to_h { |id| [id, 'fixture'] })
    [req, sha, path]
  end

end

class ReleaseTest < ReleaseFixture
  def test_process_helpers_never_interpret_a_single_command_as_shell
    marker = File.join(@root, 'shell-was-used')
    command = "printf injected > #{marker}"
    assert_raises(Errno::ENOENT) { AegisRelease.command(command, cwd: @root) }
    refute File.exist?(marker)
    flow = AegisRelease::Pipeline.new(request, Object.new)
    assert_raises(Errno::ENOENT) { flow.run(command) }
    refute File.exist?(marker)
  end

  def test_binary_command_preserves_exact_download_bytes
    assert_equal " \x00\n".b, AegisRelease.command(RbConfig.ruby, '-e', 'STDOUT.binmode; STDOUT.write(" \\x00\\n")', cwd: @root, binary: true)
  end

  def test_plan_is_read_only_and_reports_dirty_source
    write('uncommitted.txt', 'pending')
    value = request.plan
    assert value['source']['dirty']
    assert_equal 'com.gcsa.aegis', value['applicationId']
    assert_equal '3.2', value['version']
    refute File.exist?(File.join(@root, '.artifacts'))
    assert_raises(AegisRelease::Error) { AegisRelease.source(@root) }
  end

  def test_destination_matrix
    assert_equal 'testflight', request(destination: 'testflight').destination
    %w[android macos].each { |platform| assert_raises(AegisRelease::Error) { request(platform) } }
    assert_equal 'github-draft', request(destination: 'github-draft', tag: 'candidate/ios/3.2-release.69').destination
  end

  def test_candidate_namespace_and_input_injection_are_rejected
    ['v2.2.0.144', 'candidate/ios/../main', 'candidate/android/x', 'candidate/ios/x;touch x'].each do |tag|
      assert_raises(AegisRelease::Error) { request(destination: 'github-draft', tag: tag) }
    end
    ['../escape', '/tmp/out', 'a/../b', 'x$(touch bad)', 'x\ny'].each do |run_id|
      assert_raises(AegisRelease::Error) { request(run_id: run_id) }
    end
    assert_raises(AegisRelease::Error) { request(version: '3.2;echo') }
    assert_raises(AegisRelease::Error) { request(build: '0') }
    assert_raises(AegisRelease::Error) { request(force: 'true') }
  end

  def test_receipt_verifies_real_bytes_and_same_source
    req, sha, artifact = package
    receipt = AegisRelease::Receipt.verify(req, sha)
    assert_equal false, receipt['releaseReady']
    File.write(artifact, 'corrupt')
    assert_raises(AegisRelease::Error) { AegisRelease::Receipt.verify(req, sha) }
  end

  def test_receipt_rejects_missing_digest_and_edited_metadata
    req, sha = package
    assert_raises(AegisRelease::Error) { AegisRelease::Receipt.verify(req, nil) }
    File.write(req.manifest_path, File.read(req.manifest_path).sub('3.2', '3.3'))
    assert_raises(AegisRelease::Error) { AegisRelease::Receipt.verify(req, sha) }
  end

  def test_checksum_sidecar_cannot_disagree_with_the_manifest
    req, sha = package
    File.write(req.manifest_path + '.sha256', 'wrong checksum')
    assert_raises(AegisRelease::Error) { AegisRelease::Receipt.verify(req, sha) }
  end

  def test_new_commit_invalidates_previous_artifact
    req, sha = package
    write('new.txt', 'next source')
    git('add', 'new.txt')
    git('commit', '-qm', 'next')
    assert_raises(AegisRelease::Error) { AegisRelease::Receipt.verify(req, sha) }
  end

  def test_symlinked_artifact_is_not_accepted_even_with_matching_bytes
    req, sha, artifact = package
    external = write('external.bin', File.read(artifact))
    git('add', 'external.bin')
    git('commit', '-qm', 'external')
    File.unlink(artifact)
    File.symlink(external, artifact)
    assert_raises(AegisRelease::Error) { AegisRelease.digest(artifact) }
    assert_raises(AegisRelease::Error) { AegisRelease::Receipt.verify(req, sha) }
  end

  def test_symlinked_output_ancestor_is_refused
    File.symlink(Dir.tmpdir, File.join(@root, '.artifacts'))
    assert_raises(AegisRelease::Error) { AegisRelease.real_path!(request.directory) }
  end

  def test_manifest_rejects_path_traversal_and_duplicate_assets
    req, = package
    original = JSON.parse(File.read(req.manifest_path))
    [original.merge('assets' => [original['assets'][0].merge('name' => '../outside.ipa')]),
     original.merge('assets' => original['assets'] * 2)].each do |value|
      File.write(req.manifest_path, JSON.generate(value))
      sha = AegisRelease.digest(req.manifest_path)
      File.write(req.manifest_path + '.sha256', "#{sha}  #{File.basename(req.manifest_path)}\n")
      assert_raises(AegisRelease::Error) { AegisRelease::Receipt.verify(req, sha) }
    end
  end

  def test_missing_installable_asset_is_not_a_package
    req, = package
    value = JSON.parse(File.read(req.manifest_path))
    value['assets'] = []
    File.write(req.manifest_path, JSON.generate(value))
    sha = AegisRelease.digest(req.manifest_path)
    File.write(req.manifest_path + '.sha256', "#{sha}  #{File.basename(req.manifest_path)}\n")
    assert_raises(AegisRelease::Error) { AegisRelease::Receipt.verify(req, sha) }
  end

  def test_package_error_cannot_emit_a_success_receipt
    req = request
    flow = AegisRelease::Pipeline.new(req, Object.new)
    assert_raises(AegisRelease::Error) { flow.package }
    refute File.exist?(req.manifest_path)
  end

  module DraftStub
    attr_reader :mutations
    attr_accessor :remote, :tag_sha, :assets, :corrupt_upload, :on_read, :hide_from_list, :fail_after_create
    def configure_fixture
      @tag_sha = @receipt['source']['sha']
      @mutations, @assets = [], []
      self
    end
    def api(path)
      on_read&.call
      return { 'sha' => tag_sha } if path.start_with?('commits/')
      return remote if /\Areleases\/\d+\z/.match?(path)
      assets
    end
    def fetch_asset_bytes(asset)
      File.binread(File.join(@request.directory, asset.fetch('name')))
    end
    def releases
      on_read&.call
      remote && !hide_from_list ? [remote] : []
    end
    def gh(*args)
      @mutations << args
      if args[1] == 'create' || (args[0] == 'api' && args.include?('POST'))
        @remote = { 'id' => 1, 'tag_name' => @request.tag, 'draft' => true, 'prerelease' => true,
                    'target_commitish' => tag_sha, 'html_url' => 'https://github.com/gcsagroup/aegis-browser/releases/untagged/fixture' }
        raise IOError, 'creation response lost' if fail_after_create
        return JSON.generate(@remote)
      elsif args[1] == 'upload'
        path = args[3]
        @assets << { 'name' => File.basename(path), 'size' => File.size(path), 'state' => 'uploaded',
                     'digest' => corrupt_upload ? 'sha256:wrong' : "sha256:#{AegisRelease.digest(path)}" }
      end
      ''
    end
  end

  def draft
    req, sha = package('ios', destination: 'github-draft', tag: 'candidate/ios/3.2-release.69')
    receipt = AegisRelease::Receipt.verify(req, sha)
    AegisRelease::Draft.new(req, receipt, sha, environment: {}).extend(DraftStub).configure_fixture
  end

  def test_draft_downloaded_bytes_must_match_even_when_server_digest_matches
    publisher = draft
    publisher.define_singleton_method(:fetch_asset_bytes) { |_asset| 'substituted bytes' }
    assert_raises(AegisRelease::Error) { publisher.upload }
  end

  def test_admission_is_checked_at_each_draft_mutation
    publisher = draft
    publisher.instance_variable_set(:@admission, -> { raise AegisRelease::Error, 'Main advanced' })
    assert_raises(AegisRelease::Error) { publisher.upload }
    assert_empty publisher.mutations
  end

  def test_draft_creation_upload_readback_and_idempotent_retry
    publisher = draft
    assert_equal 'draft_assets_verified', publisher.upload['status']
    assert_equal 4, publisher.mutations.size # create + IPA + manifest + checksum
    creation = publisher.mutations.first
    assert_equal 'api', creation.first
    payload = JSON.parse(File.read(creation[creation.index('--input') + 1]))
    assert_equal true, payload['draft']
    assert_equal true, payload['prerelease']
    assert_equal publisher.tag_sha, payload['target_commitish']
    refute publisher.mutations.flatten.include?('--clobber')
    count = publisher.mutations.size
    publisher.hide_from_list = true
    publisher.upload
    assert_equal count, publisher.mutations.size
  end

  def test_creation_response_identifies_a_draft_not_yet_visible_in_the_inventory
    publisher = draft
    publisher.hide_from_list = true
    assert_equal 'draft_assets_verified', publisher.upload['status']
    assert_equal 4, publisher.mutations.size
  end

  def test_lost_creation_response_cannot_create_a_second_draft
    publisher = draft
    publisher.hide_from_list = true
    publisher.fail_after_create = true
    assert_raises(IOError) { publisher.upload }
    assert_raises(AegisRelease::Error) { publisher.upload }
    assert_equal 1, publisher.mutations.size
    assert_empty publisher.assets
  end

  def test_actions_rerun_cannot_create_a_draft_without_a_known_remote_or_receipt
    publisher = draft
    publisher.instance_variable_set(:@environment, { 'GITHUB_ACTIONS' => 'true', 'GITHUB_RUN_ATTEMPT' => '2' })
    assert_raises(AegisRelease::Error) { publisher.upload }
    assert_empty publisher.mutations
  end

  def test_tag_changed_during_inventory_read_cannot_create_a_release
    publisher = draft
    reads = 0
    publisher.on_read = -> { reads += 1; publisher.tag_sha = '0' * 40 if reads >= 2 }
    assert_raises(AegisRelease::Error) { publisher.upload }
    assert_empty publisher.mutations
  end

  def test_wrong_tag_prevents_all_remote_writes
    publisher = draft
    publisher.tag_sha = '0' * 40
    assert_raises(AegisRelease::Error) { publisher.upload }
    assert_empty publisher.mutations
  end

  def test_published_release_cannot_be_reused_or_changed
    publisher = draft
    publisher.upload
    publisher.remote['draft'] = false
    count = publisher.mutations.size
    assert_raises(AegisRelease::Error) { publisher.upload }
    assert_equal count, publisher.mutations.size
  end

  def test_corrupt_remote_digest_does_not_claim_upload_success
    publisher = draft
    publisher.corrupt_upload = true
    assert_raises(AegisRelease::Error) { publisher.upload }
    assert publisher.remote['draft']
  end

  def test_manifest_change_during_network_reads_is_rejected
    publisher = draft
    req = publisher.instance_variable_get(:@request)
    publisher.on_read = -> { File.write(req.manifest_path, '{}') }
    assert_raises(AegisRelease::Error) { publisher.upload }
    refute publisher.mutations.any? { |args| args[1] == 'upload' }
  end

  def test_draft_notes_cannot_follow_a_symlink
    publisher = draft
    req = publisher.instance_variable_get(:@request)
    target = File.join(req.directory, 'preserve.txt')
    File.write(target, 'preserve')
    File.symlink(target, File.join(req.directory, 'draft-notes.txt'))
    assert_raises(AegisRelease::Error) { publisher.upload }
    assert_equal 'preserve', File.read(target)
    assert_empty publisher.mutations
  end

  def test_manual_package_admission_runs_before_signing_inputs
    original_host = RbConfig::CONFIG['host_os']
    RbConfig::CONFIG['host_os'] = 'darwin'
    req = request
    flow = AegisRelease::Pipeline.new(req, Object.new)
    flow.define_singleton_method(:admit_source!) { raise AegisRelease::Error, 'Source admission denied' }
    error = assert_raises(AegisRelease::Error) { flow.package }
    assert_equal 'Source admission denied', error.message
    refute File.exist?(req.directory)
  ensure
    RbConfig::CONFIG['host_os'] = original_host
  end

  class FakeApple
    attr_reader :uploads
    attr_accessor :fail_upload
    def initialize
      @uploads = []
    end
    def app_store_connect_api_key(**_options)
      { token: 'fixture-token' }
    end
    def upload_to_testflight(**options)
      @uploads << options
      raise AegisRelease::Error, 'simulated upload connection loss' if fail_upload
    end
  end

  module PipelineStub
    def admit_source!
      true # Unit builder boundary; public package admission has a separate negative test.
    end
    def run(*_args, **_options)
      true # The separately executed Python suite tests actual IPA parsing.
    end
  end

  def fixture_pipeline(req, fastlane)
    AegisRelease::Pipeline.new(req, fastlane).extend(PipelineStub)
  end

  def test_ios_alpha_export_is_internal_only_even_for_package_and_draft
    [%w[alpha artifacts], %w[alpha github-draft], %w[beta artifacts], %w[release artifacts]].each do |profile, destination|
      options = { profile: profile, destination: destination }
      options[:tag] = "candidate/ios/3.2-#{profile}.69" if destination == 'github-draft'
      req = request(**options)
      builder = Object.new
      builder.define_singleton_method(:update_code_signing_settings) { |**_options| }
      checks = self
      builder.define_singleton_method(:build_app) do |**build_options|
        checks.assert_equal(profile == 'alpha', build_options.fetch(:export_options).fetch(:testFlightInternalTestingOnly))
        File.write(File.join(build_options.fetch(:output_directory), build_options.fetch(:output_name)), 'fixture IPA')
      end
      keys = %w[AEGIS_APPLE_TEAM_ID AEGIS_IOS_PROFILES AEGIS_IOS_CERT_SHA1]
      previous = keys.to_h { |key| [key, ENV[key]] }
      ENV['AEGIS_APPLE_TEAM_ID'] = 'ABCDEFGHIJ'
      ENV['AEGIS_IOS_CERT_SHA1'] = 'A' * 40
      ENV['AEGIS_IOS_PROFILES'] = AegisRelease::IOS_TARGETS.values.to_h { |id| [id, 'fixture'] }.to_json
      FileUtils.mkdir_p(req.directory)
      _paths, details = fixture_pipeline(req, builder).package_ios
      assert_equal profile == 'alpha', details.fetch('testFlightInternalTestingOnly')
      assert_equal 'ABCDEFGHIJ', details['appleTeamId']
      assert_equal 'A' * 40, details['certificateSha1']
    ensure
      previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    end
  end

  def test_ios_snapshot_includes_committed_shared_resources_and_excludes_local_files
    shared = 'apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared'
    write("#{shared}/viewer.html", '<html>committed viewer</html>')
    write("#{shared}/vendor/purify.min.js", 'committed sanitizer')
    vectors = 'packages/core/src/agent/contracts/v1/agent-contract-v1.vectors.json'
    write(vectors, '{"vectors":[]}')
    git('add', '.')
    git('commit', '-qm', 'shared iOS resource inputs')
    write("#{shared}/local-only.js", 'must not enter the archive')
    req = request
    builder = Object.new
    builder.define_singleton_method(:update_code_signing_settings) { |**_options| }
    checks = self
    builder.define_singleton_method(:build_app) do |**options|
      snapshot = File.expand_path('../..', File.dirname(options.fetch(:project)))
      checks.assert_equal '<html>committed viewer</html>', File.read(File.join(snapshot, shared, 'viewer.html'))
      checks.assert_equal 'committed sanitizer', File.read(File.join(snapshot, shared, 'vendor/purify.min.js'))
      checks.assert_equal '{"vectors":[]}', File.read(File.join(snapshot, vectors))
      checks.refute File.exist?(File.join(snapshot, shared, 'local-only.js'))
      File.write(File.join(options.fetch(:output_directory), options.fetch(:output_name)), 'fixture IPA')
    end
    keys = %w[AEGIS_APPLE_TEAM_ID AEGIS_IOS_PROFILES AEGIS_IOS_CERT_SHA1]
    previous = keys.to_h { |key| [key, ENV[key]] }
    ENV['AEGIS_APPLE_TEAM_ID'] = 'ABCDEFGHIJ'
      ENV['AEGIS_IOS_CERT_SHA1'] = 'A' * 40
    ENV['AEGIS_IOS_PROFILES'] = AegisRelease::IOS_TARGETS.values.to_h { |id| [id, 'fixture'] }.to_json
    fixture_pipeline(req, builder).package_ios
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def with_apple_environment
    keys = %w[AEGIS_ASC_KEY_ID AEGIS_ASC_ISSUER_ID AEGIS_ASC_KEY_BASE64]
    previous = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV[key] = 'fixture' }
    yield
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def test_testflight_success_does_not_claim_processing_or_external_distribution
    req, sha = package('ios', destination: 'testflight')
    apple = FakeApple.new
    flow = fixture_pipeline(req, apple)
    store = AegisRelease::AppleStore.new(req, apple)
    store.instance_variable_set(:@app, Struct.new(:id).new('fixture'))
    store.define_singleton_method(:authenticate) { true }
    store.define_singleton_method(:exact_build) { nil }
    store.define_singleton_method(:upload_records) { [] }
    flow.define_singleton_method(:store) { store }
    capture_io { flow.upload(sha) }
    result = JSON.parse(File.read(File.join(req.directory, 'apple-upload-result.json')))['result']
    assert_equal 'uploaded_processing_unverified', result['status']
    assert_equal false, apple.uploads.first[:distribute_external]
    assert_equal true, apple.uploads.first[:skip_submission]
    assert_equal true, apple.uploads.first[:skip_waiting_for_build_processing]
    capture_io { flow.upload(sha) }
    assert_equal 1, apple.uploads.length
  end

  def test_invalid_ipa_cannot_load_asc_credentials
    req, sha = package('ios', destination: 'testflight')
    flow = fixture_pipeline(req, FakeApple.new)
    authenticated = false
    store = Object.new
    store.define_singleton_method(:authenticate) { authenticated = true }
    flow.define_singleton_method(:store) { store }
    flow.define_singleton_method(:run) { |*_args, **_options| raise AegisRelease::Error, 'invalid IPA' }
    assert_raises(AegisRelease::Error) { flow.upload(sha) }
    assert_equal false, authenticated
  end

  def test_uncertain_testflight_outcome_preserves_attempt_and_blocks_blind_retry
    req, sha = package('ios', destination: 'testflight')
    apple = FakeApple.new
    apple.fail_upload = true
    flow = fixture_pipeline(req, apple)
    store = AegisRelease::AppleStore.new(req, apple)
    store.instance_variable_set(:@app, Struct.new(:id).new('fixture'))
    store.define_singleton_method(:authenticate) { true }
    store.define_singleton_method(:exact_build) { nil }
    store.define_singleton_method(:upload_records) { [] }
    flow.define_singleton_method(:store) { store }
    assert_raises(AegisRelease::Error) { flow.upload(sha) }
    assert File.file?(File.join(req.directory, 'apple-upload-started.json'))
    refute File.exist?(File.join(req.directory, 'apple-upload-result.json'))
    apple.fail_upload = false
    assert_raises(AegisRelease::Error) { flow.upload(sha) }
    assert_equal 1, apple.uploads.length
  end
end
