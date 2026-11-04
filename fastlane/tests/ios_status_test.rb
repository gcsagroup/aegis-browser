# frozen_string_literal: true
require_relative 'release_test'
require_relative 'ios_lifecycle_test'
require_relative '../lib/ios_status'

class IosStatusTest < Minitest::Test
  Api = IosLifecycleTest::Api

  def raw_build(audience: 'APP_STORE_ELIGIBLE')
    { 'data' => [{ 'type' => 'builds', 'id' => 'exact-build', 'attributes' => {
      'version' => '69', 'processingState' => 'VALID', 'expired' => false,
      'buildAudienceType' => audience, 'usesNonExemptEncryption' => false },
      'relationships' => { 'preReleaseVersion' => { 'data' => { 'type' => 'preReleaseVersions', 'id' => 'train' } } } }],
      'included' => [{ 'type' => 'preReleaseVersions', 'id' => 'train', 'attributes' => { 'version' => '3.2', 'platform' => 'IOS' } }] }
  end

  def query_api(document = raw_build)
    Api.new do |path, query|
      case path
      when 'apps'
        assert_equal 'com.gcsa.aegis', query.fetch('filter[bundleId]')
        { 'data' => [{ 'id' => 'app', 'attributes' => { 'bundleId' => 'com.gcsa.aegis' } }] }
      when 'builds' then document
      else { 'data' => [] }
      end
    end
  end

  def test_query_reads_exact_apple_identity_without_artifacts_or_guessed_profile
    %w[APP_STORE_ELIGIBLE INTERNAL_ONLY].each do |audience|
      api = query_api(raw_build(audience: audience))
      value = AegisRelease::BuildStatus.new(version: '3.2', build: '69', api: api).call
      assert_equal audience, value.dig('remote', 'buildAudienceType')
      assert_equal 'VALID', value.dig('remote', 'processingState')
      assert_equal false, value['packageProvenanceVerified']
      refute value.key?('profile')
      assert api.calls.all? { |row| row.first == :get }
    end
  end

  def test_no_latest_fallback_and_ambiguous_app_or_build_fails
    value = AegisRelease::BuildStatus.new(version: '9.9', build: '69', api: query_api).call
    assert_equal 'NOT_FOUND', value.dig('remote', 'processingState')
    [[], [{ 'id' => 'wrong', 'attributes' => { 'bundleId' => 'other' } }]].each do |apps|
      api = Api.new { |*, **| { 'data' => apps } }
      assert_raises(AegisRelease::Error) { AegisRelease::BuildStatus.new(version: '3.2', build: '69', api: api).call }
    end
    doc = raw_build
    doc['data'] *= 2
    assert_raises(AegisRelease::Error) { AegisRelease::BuildStatus.new(version: '3.2', build: '69', api: query_api(doc)).call }
  end

  def test_invalid_identifiers_fail_before_any_network_read
    api = Api.new { raise 'Network must not be called' }
    [['3.2', '01'], ['3.2', ''], ["3.2\n", '1'], ['$(id)', '1'], ['3.2', '1;id']].each do |version, build|
      assert_raises(AegisRelease::Error) { AegisRelease::BuildStatus.new(version: version, build: build, api: api) }
    end
    assert_empty api.calls
  end
  def test_read_only_wait_stops_at_valid_and_never_selects_another_build
    query = AegisRelease::BuildStatus.new(version: '3.2', build: '69', api: query_api)
    rows = [
      { 'remote' => { 'processingState' => 'PROCESSING', 'uploadState' => 'COMPLETE' } },
      { 'remote' => { 'processingState' => 'VALID', 'uploadState' => 'COMPLETE', 'expired' => false } }
    ]
    query.define_singleton_method(:call) { rows.shift }
    time = 0
    result = query.wait(timeout: 30, interval: 15, clock: -> { time }, sleeper: ->(seconds) { time += seconds })
    assert_equal 'VALID', result.dig('remote', 'processingState')
    assert_equal 15, time
  end

  def test_default_wait_allows_apple_processing_beyond_five_minutes_without_mutation
    document = raw_build
    document['data'].first['attributes']['processingState'] = 'PROCESSING'
    api = query_api(document)
    query = AegisRelease::BuildStatus.new(version: '3.2', build: '69', api: api)
    time = 0
    result = query.wait(clock: -> { time }, sleeper: lambda { |seconds|
      time += seconds
      document['data'].first['attributes']['processingState'] = 'VALID' if time >= 900
    })
    assert_equal 900, time
    assert_equal 'VALID', result.dig('remote', 'processingState')
    assert_equal ['3.2', '69'], result.values_at('version', 'build')
    assert_equal false, result.fetch('packageProvenanceVerified')
    assert api.calls.all? { |row| row.first == :get }
  end

  def test_wait_rejects_absent_failed_expired_and_times_out_without_upload
    [ ['NOT_FOUND', 'NOT_FOUND', false], ['INVALID', 'COMPLETE', false], ['PROCESSING', 'FAILED', false], ['VALID', 'COMPLETE', true] ].each do |state, upload, expired|
      query = AegisRelease::BuildStatus.new(version: '3.2', build: '69', api: query_api)
      query.define_singleton_method(:call) { { 'remote' => { 'processingState' => state, 'uploadState' => upload, 'expired' => expired } } }
      assert_raises(AegisRelease::Error) { query.wait }
    end
    query = AegisRelease::BuildStatus.new(version: '3.2', build: '69', api: query_api)
    query.define_singleton_method(:call) { { 'remote' => { 'processingState' => 'PROCESSING', 'uploadState' => 'COMPLETE' } } }
    time = 0
    error = assert_raises(AegisRelease::BuildStatus::WaitTimeout) { query.wait(timeout: 1, interval: 1, clock: -> { time }, sleeper: ->(seconds) { time += seconds }) }
    assert_equal 1, time
    assert_equal 1, error.timeout
    assert_equal 'PROCESSING', error.status.dig('remote', 'processingState')
    assert_match(/no upload or retry performed/, error.message)
  end

  def test_default_wait_still_expires_and_rejects_unbounded_waits
    document = raw_build
    document['data'].first['attributes']['processingState'] = 'PROCESSING'
    api = query_api(document)
    query = AegisRelease::BuildStatus.new(version: '3.2', build: '69', api: api)
    time = 0
    error = assert_raises(AegisRelease::BuildStatus::WaitTimeout) do
      query.wait(clock: -> { time }, sleeper: ->(seconds) { time += seconds })
    end
    assert_equal 1800, time
    assert_equal 1800, error.timeout
    assert_equal ['3.2', '69'], error.status.values_at('version', 'build')
    assert api.calls.all? { |row| row.first == :get }
    [[0, 15], [1801, 15], [30, 0], [30, 31]].each do |timeout, interval|
      before = api.calls.size
      assert_raises(AegisRelease::Error) { query.wait(timeout: timeout, interval: interval) }
      assert_equal before, api.calls.size
    end
  end

  def test_missing_forwarded_credentials_fail_before_token_construction_without_echoing_values
    env = { 'AEGIS_ASC_KEY_ID' => 'fixture-id', 'AEGIS_ASC_ISSUER_ID' => 'fixture-issuer', 'AEGIS_ASC_KEY_BASE64' => Base64.strict_encode64('fixture-key') }
    assert_equal 'fixture-key', AegisRelease::BuildStatus.token_options(env).fetch(:key)
    env.each_key do |name|
      ['', nil].each do |missing|
        error = assert_raises(AegisRelease::Error) { AegisRelease::BuildStatus.token_options(env.merge(name => missing)) }
        assert_match(/credentials missing/, error.message)
        refute_match(/fixture-key|fixture-id|fixture-issuer/, error.message)
      end
    end
    assert_raises(AegisRelease::Error) { AegisRelease::BuildStatus.token_options(env.merge('AEGIS_ASC_KEY_BASE64' => '***invalid***')) }
  end

end
