# frozen_string_literal: true
require 'minitest/autorun'
require 'open3'
require 'json'

class IosReleaseCliTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CLI = File.join(ROOT, 'scripts/release/cli.rb')

  def cli(*args)
    Open3.capture3({ 'GITHUB_ACTIONS' => nil, 'AEGIS_ASC_KEY_PATH' => '/missing-test-key.p8' },
                  RbConfig.ruby, CLI, *args, chdir: ROOT)
  end

  # Removing the profile destination guard must make these policy tests fail.
  def test_alpha_internal_plan_is_source_bound_and_read_only
    text, error, status = cli('ios', 'plan', '--profile', 'alpha', '--destination', 'testflight-internal',
                              '--version', '1.0.0', '--build', '6')
    assert status.success?, error
    value = JSON.parse(text)
    assert_equal ['ios', 'alpha', '1.0.0', '6', 'ipa'], value.values_at('platform', 'profile', 'version', 'build', 'format')
    assert_match(/\A[0-9a-f]{40}\z/, value.fetch('source').fetch('sha'))
    assert_equal false, value.fetch('uploadSubmitsReview')
    assert_equal false, value.fetch('releaseReady')
  end

  def test_alpha_external_route_fails_before_reading_any_credential
    _text, error, status = cli('ios', 'upload', '--profile', 'alpha', '--destination', 'testflight-external')
    refute status.success?
    assert_match(/Alpha.*internal/i, error)
    refute_match(/missing-test-key/, error)
  end

  def test_beta_production_submit_is_rejected_before_upload_or_authentication
    _text, error, status = cli('ios', 'submit', '--profile', 'beta', '--destination', 'app-store')
    refute status.success?
    assert_match(/release.*profile|profile.*release|Beta.*submit/i, error)
    refute_match(/missing-test-key/, error)
  end

  def test_release_production_plan_does_not_submit
    text, error, status = cli('ios', 'plan', '--profile', 'release', '--destination', 'app-store')
    assert status.success?, error
    assert_equal false, JSON.parse(text).fetch('uploadSubmitsReview')
  end

  def test_mutations_need_an_explicit_profile
    _text, error, status = cli('ios', 'upload', '--destination', 'testflight')
    refute status.success?
    assert_match(/explicit.*profile|--profile.*required/i, error)
  end

  def test_non_ios_platform_cannot_reach_a_release_stage
    _text, error, status = cli('android', 'plan', '--profile', 'release')
    refute status.success?
    assert_match(/Only iOS|Platform must be ios/i, error)
  end

  def test_draft_tag_cannot_mislabel_the_immutable_profile
    _text, error, status = cli('ios', 'plan', '--profile', 'alpha', '--version', '1.0.0', '--build', '6',
                               '--destination', 'github-draft', '--tag', 'candidate/ios/1.0.0-release.6')
    refute status.success?
    assert_match(/tag.*identity|tag.*profile/i, error)
  end

  def test_path_traversal_run_id_is_rejected
    _text, error, status = cli('ios', 'plan', '--profile', 'beta', '--run-id', '../escape')
    refute status.success?
    assert_match(/run ID/i, error)
  end
end
