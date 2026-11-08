# frozen_string_literal: true
# Delete an empty ASC buildUpload (AWAITING_UPLOAD, no files, no uploadedDate).
require_relative '../../fastlane/lib/ios_status'

version = ENV.fetch('RELEASE_VERSION')
build = ENV.fetch('RELEASE_BUILD')
source = AegisRelease.source
AegisRelease.command('node', File.join(AegisRelease::ROOT, 'scripts/ci/ios-release-preflight.mjs'), '--sha', source.fetch('sha'))
require 'spaceship'
token = Spaceship::ConnectAPI::Token.create(**AegisRelease::BuildStatus.token_options)
api = AegisRelease::AscApi.new(token: token, read_only: false)
status = AegisRelease::BuildStatus.new(version: version, build: build, api: api).call
remote = status.fetch('remote')
uploads = remote.fetch('uploads')
AegisRelease.require!(remote['buildId'].nil? && remote.fetch('processingState') == 'NOT_FOUND',
                      'Refusing to clear: a processed build already exists for this version/build')
AegisRelease.require!(uploads.size == 1, 'Refusing to clear: expected exactly one upload reservation')
record = uploads.first
attrs = record.fetch('attributes')
id = record.fetch('id')
state = attrs.dig('state', 'state')
AegisRelease.require!(record['type'] == 'buildUploads' && state == 'AWAITING_UPLOAD' &&
                      attrs['uploadedDate'].nil? && attrs.dig('state', 'errors') == [] &&
                      attrs.values_at('cfBundleShortVersionString', 'cfBundleVersion', 'platform') == [version, build, 'IOS'],
                      'Refusing to clear: reservation is not an empty AWAITING_UPLOAD for this identity')
files = api.collection("buildUploads/#{id}/buildUploadFiles").fetch('data')
AegisRelease.require!(files.empty?, 'Refusing to clear: reservation already has upload files')
api.delete("buildUploads/#{id}")
after = AegisRelease::BuildStatus.new(version: version, build: build, api: api).call.fetch('remote')
AegisRelease.require!(after['buildId'].nil? && after.fetch('uploads').empty? &&
                      after.fetch('processingState') == 'NOT_FOUND' && after.fetch('uploadState') == 'NOT_FOUND',
                      'Clear completed but ASC still reports this version/build')
result = {
  'cleared' => true,
  'version' => version,
  'build' => build,
  'uploadId' => id,
  'before' => { 'uploadState' => remote['uploadState'], 'uploads' => 1 },
  'after' => { 'uploadState' => after['uploadState'], 'uploads' => 0 },
  'observedAt' => after['observedAt']
}
path = File.join(AegisRelease::ROOT, '.artifacts/ios-status/clear-empty-upload.json')
FileUtils.mkdir_p(File.dirname(path))
File.write(path, JSON.pretty_generate(result) + "\n")
puts JSON.pretty_generate(result)
