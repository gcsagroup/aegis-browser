# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'json'
require 'fileutils'

class IosStatusCliTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def run_query(state: 'PROCESSING', mode: 'wait', failure: nil)
    Dir.mktmpdir('aegis-status-cli-') do |directory|
      value = { 'platform' => 'ios', 'version' => '1.0.1', 'build' => '14', 'readOnly' => true,
                'packageProvenanceVerified' => false,
                'remote' => { 'processingState' => state, 'uploadState' => 'COMPLETE', 'expired' => false,
                              'buildId' => 'exact-build', 'uploads' => [], 'observedAt' => '2026-11-04T00:00:00Z' } }
      File.write(File.join(directory, 'spaceship.rb'), <<~'RUBY')
        module Spaceship
          module ConnectAPI
            class Token
              def self.create(**)
                File.write(File.join(ENV.fetch('STATUS_TEST_ROOT'), 'token-created'), 'fixture')
                Object.new
              end
            end
          end
        end
      RUBY
      preload = File.join(directory, 'preload.rb')
      File.write(preload, "require #{File.join(ROOT, 'fastlane/lib/ios_status').inspect}\n" + <<~'RUBY')
        module AegisRelease
          remove_const(:ROOT)
          ROOT = ENV.fetch('STATUS_TEST_ROOT')
          def self.source(*) = { 'sha' => 'a' * 40, 'tree' => 'b' * 40, 'dirty' => false }
          def self.command(*)
            raise Error, 'Admin required' if ENV['STATUS_TEST_FAILURE'] == 'preflight'
            ''
          end
          class BuildStatus
            alias_method :original_wait, :wait
            def wait
              time = 0
              original_wait(timeout: 1, interval: 1, clock: -> { time }, sleeper: ->(seconds) { time += seconds })
            end
            def call
              raise Error, 'ASC response unavailable' if ENV['STATUS_TEST_FAILURE'] == 'network'
              JSON.parse(ENV.fetch('STATUS_TEST_VALUE'))
            end
          end
        end
      RUBY
      summary_path = File.join(directory, 'summary.md')
      environment = { 'STATUS_TEST_ROOT' => directory, 'STATUS_TEST_VALUE' => JSON.generate(value),
                      'STATUS_TEST_FAILURE' => failure, 'RELEASE_VERSION' => '1.0.1', 'RELEASE_BUILD' => '14',
                      'RELEASE_QUERY_MODE' => mode, 'GITHUB_STEP_SUMMARY' => summary_path,
                      'AEGIS_ASC_KEY_ID' => 'fixture-id', 'AEGIS_ASC_ISSUER_ID' => 'fixture-issuer',
                      'AEGIS_ASC_KEY_BASE64' => ['fixture-key'].pack('m0') }
      text, error, process = Open3.capture3(environment, RbConfig.ruby, '-I', directory, '-r', preload,
                                            File.join(ROOT, 'scripts/release/ios-status.rb'))
      report_path = File.join(directory, '.artifacts/ios-status/status.json')
      yield({ text: text, error: error, process: process,
              report: File.file?(report_path) ? JSON.parse(File.read(report_path)) : nil,
              summary: File.file?(summary_path) ? File.read(summary_path) : nil,
              token_created: File.file?(File.join(directory, 'token-created')) })
    end
  end

  def test_wait_timeout_retains_pending_evidence_and_still_exits_nonzero
    run_query do |result|
      refute result[:process].success?
      assert_match(/Processing wait timed out/, result[:error])
      report = result.fetch(:report)
      assert_equal 'timed_out', report.fetch('waitOutcome')
      assert_equal 1, report.fetch('waitTimeoutSeconds')
      assert_equal 'PROCESSING', report.dig('remote', 'processingState')
      assert_equal ['1.0.1', '14', 'wait', false], report.values_at('version', 'build', 'queryMode', 'packageProvenanceVerified')
      assert_equal 'a' * 40, report.dig('querySource', 'sha')
      assert_equal report, JSON.parse(result[:text])
      assert_match(/Wait timed out.*last observed Apple state/, result[:summary])
    end
  end

  def test_valid_wait_and_plain_status_keep_their_success_semantics
    [{ state: 'VALID' }, { state: 'PROCESSING', mode: 'status' }].each do |options|
      run_query(**options) do |result|
        assert result[:process].success?, result[:error]
        assert_equal options.fetch(:state), result[:report].dig('remote', 'processingState')
        refute result[:report].key?('waitOutcome')
        refute_match(/Wait timed out/, result[:summary])
      end
    end
  end

  def test_preflight_and_network_errors_are_not_converted_to_timeout_reports
    %w[preflight network].each do |failure|
      run_query(failure: failure) do |result|
        refute result[:process].success?
        assert_nil result[:report]
        assert_nil result[:summary]
        refute_match(/Processing wait timed out/, result[:error])
        refute result[:token_created] if failure == 'preflight'
      end
    end
  end

  def test_unused_mode_still_rejects_an_existing_build
    run_query(mode: 'unused') do |result|
      refute result[:process].success?
      assert_match(/Apple already has this version\/build/, result[:error])
      assert_nil result[:report]
    end
  end
end
