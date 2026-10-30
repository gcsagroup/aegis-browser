# frozen_string_literal: true
require_relative 'release_test'
require 'ostruct'
require 'uri'
begin
  require_relative '../lib/asc_api'
rescue LoadError
  # The public adapter is introduced by this task; its behavior tests run after RED.
end

class AscApiTest < Minitest::Test
  def api(responses, token: nil, &observe)
    assert AegisRelease.const_defined?(:AscApi), 'Exact ASC HTTP adapter is not implemented'
    token ||= OpenStruct.new(text: 'fixture-token')
    token.define_singleton_method(:expired?) { false } unless token.respond_to?(:expired?)
    transport = lambda do |uri, request|
      observe&.call(uri, request)
      value = responses.shift
      raise value if value.is_a?(Exception)
      value
    end
    AegisRelease::AscApi.new(token: token, transport: transport)
  end

  def response(data = nil, status: 200, **fields)
    data ||= fields
    { status: status, body: JSON.generate(data) }
  end

  def test_query_filters_and_authorization_are_sent_to_fixed_apple_host
    seen = []
    client = api([response('data' => [])]) { |uri, request| seen << [uri, request] }
    assert_equal [], client.get('apps', 'filter[bundleId]' => 'com.gcsa.aegis')['data']
    assert_equal 'api.appstoreconnect.apple.com', seen.first[0].host
    assert_equal({ 'filter[bundleId]' => 'com.gcsa.aegis' }, URI.decode_www_form(seen.first[0].query).to_h)
    assert_equal 'Bearer fixture-token', seen.first[1]['Authorization']
  end

  def test_a_mutation_transport_failure_is_never_automatically_retried
    calls = 0
    client = api([IOError.new('lost response')]) { calls += 1 }
    assert_raises(AegisRelease::Error) { client.post('builds', 'data' => { 'type' => 'builds' }) }
    assert_equal 1, calls
  end

  def test_server_error_does_not_echo_sensitive_response_body_or_retry
    calls = 0
    client = api([response({ 'errors' => [{ 'code' => 'SERVER_ERROR', 'detail' => 'sensitive diagnostic' }] }, status: 503)]) { calls += 1 }
    error = assert_raises(AegisRelease::Error) { client.patch('builds/example', 'data' => {}) }
    assert_match(/503/, error.message)
    refute_match(/sensitive diagnostic/, error.message)
    assert_equal 1, calls
  end

  def test_pagination_cannot_send_a_token_to_another_host
    calls = 0
    client = api([response('data' => [], 'links' => { 'next' => 'https://example.invalid/steal' })]) { calls += 1 }
    assert_raises(AegisRelease::Error) { client.collection('builds') }
    assert_equal 1, calls
  end

  def test_pagination_combines_records_and_related_versions
    client = api([response('data' => [{ 'id' => 'one' }], 'included' => [{ 'type' => 'preReleaseVersions', 'id' => 'v1' }],
                           'links' => { 'next' => 'https://api.appstoreconnect.apple.com/v1/builds?cursor=next' }),
                  response('data' => [{ 'id' => 'two' }], 'included' => [{ 'type' => 'preReleaseVersions', 'id' => 'v2' }])])
    value = client.collection('builds')
    assert_equal %w[one two], value['data'].map { |r| r['id'] }
    assert_equal %w[v1 v2], value['included'].map { |r| r['id'] }
  end

  def test_expired_token_is_refreshed_before_any_request
    token = OpenStruct.new(text: 'expired-fixture')
    token.define_singleton_method(:expired?) { text == 'expired-fixture' }
    token.define_singleton_method(:refresh!) { self.text = 'fresh-fixture' }
    observed = nil
    client = api([response('data' => [])], token: token) { |_uri, request| observed = request['Authorization'] }
    client.get('apps')
    assert_equal 'Bearer fresh-fixture', observed
  end
end
