# frozen_string_literal: true
require_relative '../../fastlane/lib/ios_status'
require 'digest'

# Authorize and recheck the committed query implementation before reading credentials.
source = AegisRelease.source
AegisRelease.command('node', File.join(AegisRelease::ROOT, 'scripts/ci/ios-release-preflight.mjs'), '--sha', source.fetch('sha'))
require 'spaceship'
token = Spaceship::ConnectAPI::Token.create(**AegisRelease::BuildStatus.token_options)
api = AegisRelease::AscApi.new(token: token, read_only: true)
query = AegisRelease::BuildStatus.new(version: ENV.fetch('RELEASE_VERSION'), build: ENV.fetch('RELEASE_BUILD'), api: api)
mode = ENV.fetch('RELEASE_QUERY_MODE', 'status')
AegisRelease.require!(%w[status wait release-wait unused].include?(mode), 'Unknown read-only query mode')
wait_error = nil
begin
  value = %w[wait release-wait].include?(mode) ? query.wait : query.call
rescue AegisRelease::BuildStatus::WaitTimeout => wait_error
  value = wait_error.status
  value['waitOutcome'] = 'timed_out'
  value['waitTimeoutSeconds'] = wait_error.timeout
rescue StandardError
  raise unless mode == 'release-wait'
  abort 'Apple Release Wait failed. No public receipt was written.'
end
if mode == 'release-wait'
  abort 'Apple Release Wait timed out. No public receipt was written.' if wait_error
  # Keep ASC upload records, group information and raw build identity in memory.
  remote = value.fetch('remote')
  value = value.slice('platform', 'applicationId', 'version', 'build', 'readOnly', 'packageProvenanceVerified')
  value['remote'] = remote.slice('appId', 'processingState', 'uploadState', 'expired', 'observedAt')
  value['remote']['buildIdentitySha256'] = Digest::SHA256.hexdigest(remote.fetch('buildId'))
end
if mode == 'unused'
  remote = value.fetch('remote')
  AegisRelease.require!(remote['buildId'].nil? && remote.fetch('uploads').empty?,
                        'Apple already has this version/build or upload; query it instead of rebuilding/reuploading')
end
value['queryMode'] = mode
value['querySource'] = source # Implementation source, never asserted as the queried binary's source.
path = File.join(AegisRelease::ROOT, '.artifacts/ios-status/status.json')
FileUtils.mkdir_p(File.dirname(path))
File.write(path, JSON.pretty_generate(value) + "\n")
puts JSON.pretty_generate(value)
if ENV['GITHUB_STEP_SUMMARY']
  remote = value.fetch('remote')
  fields = { 'Version' => value.fetch('version'), 'Build' => value.fetch('build'),
             'Processing' => remote.fetch('processingState'), 'Audience' => remote['buildAudienceType'],
             'Internal' => remote['internalState'], 'External' => remote['externalState'],
             'Expired' => remote['expired'], 'Observed' => remote['observedAt'] }
  File.open(ENV['GITHUB_STEP_SUMMARY'], 'a') do |summary|
    summary.puts "## TestFlight Status\n\n| Field | Value |\n|---|---|"
    fields.each { |key, item| summary.puts "| #{key} | #{item.nil? ? '-' : item.to_s.gsub('|', '&#124;').gsub(/[\r\n]/, ' ')} |" }
    summary.puts "\n**Wait timed out after #{wait_error.timeout} seconds.** This is the last observed Apple state. Use Status or Wait to check again; no upload was retried." if wait_error
    summary.puts "\nThis operation reads TestFlight status."
    summary.puts "\n#{remote['processingState'] == 'NOT_FOUND' ? 'Apple did not return a build for this exact version and build number.' : 'Apple state only; audience does not identify Beta versus Release or verify package provenance.'}"
  end
end
raise wait_error if wait_error
