# frozen_string_literal: true
require_relative 'release_test'

class IosLifecycleTest < ReleaseFixture
  class Api
    attr_reader :calls
    def initialize(&read)
      @read, @calls = read, []
    end
    def collection(path, query = {})
      @calls << [:get, path, query]
      @read.call(path, query)
    end
    def get(path, query = {}) = collection(path, query)
    def patch(path, body)
      @calls << [:patch, path, body]
      { 'data' => body.fetch('data') }
    end
    def post(path, body)
      @calls << [:post, path, body]
      { 'data' => body.fetch('data').merge('id' => 'created') }
    end
  end

  def raw_build(version: '3.2', audience: 'APP_STORE_ELIGIBLE', expired: false, encryption: false)
    { 'data' => [{ 'type' => 'builds', 'id' => 'exact-build', 'attributes' => {
      'version' => '69', 'processingState' => 'VALID', 'expired' => expired,
      'buildAudienceType' => audience, 'usesNonExemptEncryption' => encryption },
      'relationships' => { 'preReleaseVersion' => { 'data' => { 'type' => 'preReleaseVersions', 'id' => 'train' } } } }],
      'included' => [{ 'type' => 'preReleaseVersions', 'id' => 'train', 'attributes' => { 'version' => version, 'platform' => 'IOS' } }] }
  end

  def client(api, **options)
    AegisRelease::AppleStore.new(request(**options), Object.new, api: api, app_id: 'app')
  end

  def test_exact_build_rejects_other_version_train_and_never_selects_latest
    api = Api.new { |path, _| path == 'builds' ? raw_build(version: '9.9') : { 'data' => [] } }
    assert_nil client(api).exact_build
  end

  def test_status_distinguishes_processing_failed_complete_and_absent_uploads
    %w[PROCESSING FAILED COMPLETE NOT_FOUND].each do |state|
      api = Api.new do |path, _|
        path == 'builds' || state == 'NOT_FOUND' ? { 'data' => [] } :
          { 'data' => [{ 'id' => 'upload', 'attributes' => { 'state' => { 'state' => state, 'errors' => [] } } }] }
      end
      assert_equal state, client(api).status.fetch('uploadState')
    end
  end

  def test_alpha_must_read_back_internal_only_and_expired_builds_cannot_distribute
    api = Api.new { |_path, _| raw_build }
    assert_raises(AegisRelease::Error) { client(api, profile: 'alpha').processed_build }
    api = Api.new { |_path, _| raw_build(expired: true) }
    assert_raises(AegisRelease::Error) { client(api).processed_build }
    api = Api.new { |_path, _| raw_build(audience: 'INTERNAL_ONLY') }
    assert_equal 'exact-build', client(api, profile: 'alpha').processed_build.fetch('id')
  end

  def test_wait_stops_on_failed_upload_without_sleep_or_mutation
    api = Api.new do |path, _|
      { 'data' => path == 'builds' ? [] : [{ 'id' => 'u', 'attributes' => { 'state' => { 'state' => 'FAILED' } } }] }
    end
    assert_raises(AegisRelease::Error) { client(api).wait_for_processing(timeout: 1, interval: 1) }
    assert api.calls.all? { |call| call.first == :get }
  end

  def test_existing_processing_upload_blocks_duplicate_binary_before_pilot
    api = Api.new { |path, _| { 'data' => path == 'builds' ? [] : [{ 'id' => 'u' }] } }
    assert_raises(AegisRelease::Error) { client(api).upload('unused.ipa') }
  end

  def test_metadata_validates_every_locale_before_any_mutation
    api = Api.new { |_path, _| raw_build }
    assert_raises(AegisRelease::Error) do
      client(api).validate_metadata!('locales' => { 'en-US' => { 'description' => 'valid' }, 'zh-Hans' => { 'feedbackEmail' => 'forbidden' } })
    end
    refute api.calls.any? { |call| call.first != :get }
  end

  def test_compliance_requires_explicit_boolean_authorization_and_exact_source
    api = Api.new { |_path, _| raw_build(encryption: nil) }
    store = client(api)
    source = AegisRelease.source(@root).fetch('sha')
    scope = AegisRelease.native_inputs_digest(@root)
    declaration = { 'usesNonExemptEncryption' => false, 'sourceSha' => source, 'nativeInputsSha256' => scope, 'authorization' => 'operator reviewed system encryption' }
    assert_equal false, store.validate_compliance!(declaration).fetch('usesNonExemptEncryption')
    [declaration.reject { |k, _| k == 'usesNonExemptEncryption' }, declaration.merge('sourceSha' => '0' * 40),
     declaration.merge('nativeInputsSha256' => '0' * 64), declaration.merge('authorization' => '')].each do |bad|
      assert_raises(AegisRelease::Error) { store.validate_compliance!(bad) }
    end
    refute api.calls.any? { |call| call.first != :get }
  end

  def test_conflicting_existing_encryption_answer_is_preserved
    api = Api.new { |_path, _| raw_build(encryption: true) }
    assert_raises(AegisRelease::Error) { client(api).compliance('usesNonExemptEncryption' => false) }
    refute api.calls.any? { |call| call.first != :get }
  end
  def test_unscoped_compliance_declaration_cannot_be_accepted_even_if_answer_matches
    api = Api.new { |_path, _| raw_build(encryption: false) }
    assert_raises(AegisRelease::Error) { client(api).compliance('usesNonExemptEncryption' => false) }
    refute api.calls.any? { |call| call.first != :get }
  end

  def test_group_type_mismatch_is_rejected_without_mutation
    api = Api.new { |_path, _| { 'data' => [{ 'id' => 'external', 'attributes' => { 'name' => 'group', 'isInternalGroup' => false } }] } }
    assert_raises(AegisRelease::Error) { client(api, destination: 'testflight-internal', groups: 'group').groups }
    refute api.calls.any? { |call| call.first != :get }
  end

  def test_metadata_patch_preserves_contacts_and_other_locales
    localizations = [{ 'id' => 'en', 'attributes' => { 'locale' => 'en-US', 'description' => 'old', 'feedbackEmail' => 'preserve@example.invalid' } },
                     { 'id' => 'zh', 'attributes' => { 'locale' => 'zh-Hans', 'description' => 'untouched' } }]
    api = Api.new do |path, _|
      if path == 'builds'
        raw_build
      elsif path.end_with?('betaAppLocalizations')
        { 'data' => localizations }
      else
        { 'data' => [] }
      end
    end
    api.define_singleton_method(:patch) do |path, body|
      @calls << [:patch, path, body]
      localizations.first['attributes'].merge!(body['data']['attributes'])
      { 'data' => body['data'] }
    end
    result = client(api).metadata('locales' => { 'en-US' => { 'description' => 'new' } })
    assert_equal 'metadata_read_verified', result['status']
    assert_equal 'preserve@example.invalid', localizations.first['attributes']['feedbackEmail']
    assert_equal 'untouched', localizations.last['attributes']['description']
    assert_equal({ 'description' => 'new' }, api.calls.find { |call| call.first == :patch }.last['data']['attributes'])
  end

  def test_status_reports_raw_tester_state_without_claiming_this_build_was_installed
    doc = raw_build
    doc['data'].first['relationships']['betaGroups'] = { 'data' => [{ 'type' => 'betaGroups', 'id' => 'internal' }] }
    doc['included'] << { 'type' => 'betaGroups', 'id' => 'internal', 'attributes' => { 'name' => 'early', 'isInternalGroup' => true } }
    api = Api.new do |path, _|
      if path == 'builds'
        doc
      elsif path.end_with?('/betaTesters')
        { 'data' => [{ 'id' => 'one', 'attributes' => { 'state' => 'INSTALLED' } }, { 'id' => 'two', 'attributes' => { 'state' => 'INVITED' } }] }
      else
        { 'data' => [] }
      end
    end
    result = client(api).status
    assert_equal({ 'INSTALLED' => 1, 'INVITED' => 1 }, result.fetch('groups').first.fetch('testerStates'))
    assert_equal 'not_verified', result.fetch('deviceAcceptance')
  end

  def test_successful_internal_assignment_uses_supported_build_relationship_readback
    doc = raw_build(audience: 'INTERNAL_ONLY')
    selected = { 'id' => 'internal', 'attributes' => { 'name' => 'early', 'isInternalGroup' => true } }
    api = Api.new do |path, _|
      raise AegisRelease::Error, '403: betaGroups does not allow GET_RELATED' if path == 'builds/exact-build/betaGroups'
      if path == 'builds'
        doc
      elsif path.end_with?('/betaTesters')
        { 'data' => [{ 'id' => 'one', 'attributes' => { 'state' => 'INSTALLED' } }] }
      else
        { 'data' => [] }
      end
    end
    api.define_singleton_method(:post) do |path, body|
      @calls << [:post, path, body]
      doc['data'].first['relationships']['betaGroups'] = { 'data' => body.fetch('data') }
      doc['included'] << selected.merge('type' => 'betaGroups')
      {}
    end
    result = client(api, profile: 'alpha', destination: 'testflight-internal', groups: 'early').distribute([selected])
    assert_equal 'testflight_groups_assigned', result.fetch('status')
    assert_equal({ 'INSTALLED' => 1 }, result.fetch('groups').first.fetch('testerStates'))
    assert_equal 1, api.calls.count { |call| call.first == :post }
    refute api.calls.any? { |call| call[1] == 'builds/exact-build/betaGroups' }
  end

end
