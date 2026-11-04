# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/cloud_poc'

class CloudPocStoreTest < Minitest::Test
  class FakeStore
    attr_reader :uploads
    attr_accessor :wait_fails
    def initialize = @uploads = 0
    def status = {'processingState' => 'NOT_FOUND', 'uploadState' => 'NOT_FOUND', 'uploads' => [], 'observedAt' => Time.now.utc.iso8601}
    def exact_build = nil
    def upload_records = []
    def upload(_ipa, **_options)
      @uploads += 1
      {'status' => 'uploaded_processing_unverified', 'reviewSubmitted' => false}
    end
    def wait_for_processing(**_options)
      raise AegisRelease::Error, 'processing timeout' if wait_fails
      {'processingState' => 'VALID', 'buildAudienceType' => 'APP_STORE_ELIGIBLE'}
    end
  end

  def setup
    @root = File.realpath(Dir.mktmpdir)
    @environment = %w[POC_VERSION POC_BUILD POC_RUN_ID POC_UPLOAD GITHUB_RUN_ATTEMPT].to_h { |key| [key, ENV[key]] }
    ENV.update('POC_VERSION' => '0.8.0', 'POC_BUILD' => '101', 'POC_RUN_ID' => 'test-1', 'POC_UPLOAD' => 'true', 'GITHUB_RUN_ATTEMPT' => '1')
    @flow = AegisRelease::CloudPocStore.new(Object.new, root: @root)
    @client = FakeStore.new
    client = @client
    @flow.define_singleton_method(:admission!) { {'sha' => 'a' * 40, 'tree' => 'b' * 40} }
    @flow.define_singleton_method(:verify_package) { |_source| [{'ipaSha256' => 'c' * 64, 'dsymSha256' => 'd' * 64}, 'fixture.ipa'] }
    @flow.define_singleton_method(:store) { client }
    FileUtils.mkdir_p(@flow.directory)
    File.write(File.join(@flow.directory, 'poc-receipt.json'), '{}')
    @flow.preflight
  end

  def teardown
    @environment.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    FileUtils.remove_entry(@root)
  end

  def test_upload_is_explicit_and_never_replayed_on_a_rerun
    ENV['POC_UPLOAD'] = 'false'
    assert_raises(AegisRelease::Error) { @flow.upload_and_wait }
    ENV['POC_UPLOAD'] = 'true'
    ENV['GITHUB_RUN_ATTEMPT'] = '2'
    assert_raises(AegisRelease::Error) { @flow.upload_and_wait }
    assert_equal 0, @client.uploads
  end

  def test_verified_upload_and_processing_are_separate_receipts_without_review
    assert_equal 'VALID', @flow.upload_and_wait['processingState']
    result = JSON.parse(File.read(File.join(@flow.state_directory, 'upload-result.json')))
    assert_equal false, result['reviewSubmitted']
    assert_equal 'uploaded_processing_unverified', result['result']['status']
    assert File.file?(File.join(@flow.state_directory, 'processing-result.json'))
    assert_raises(AegisRelease::Error) { @flow.upload_and_wait }
    assert_equal 1, @client.uploads
  end

  def test_processing_failure_retains_completed_upload_and_blocks_duplicate_transport
    @client.wait_fails = true
    assert_raises(AegisRelease::Error) { @flow.upload_and_wait }
    assert File.file?(File.join(@flow.state_directory, 'upload-result.json'))
    refute File.exist?(File.join(@flow.state_directory, 'processing-result.json'))
    @client.wait_fails = false
    assert_raises(AegisRelease::Error) { @flow.upload_and_wait }
    assert_equal 1, @client.uploads
  end
end
