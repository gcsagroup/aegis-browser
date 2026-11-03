# frozen_string_literal: true
require_relative '../../fastlane/lib/ios_status'
require 'spaceship'
require 'base64'

# GET only. Provisioning profiles are shared by Alpha, Beta and Release exports.
directory = File.expand_path(ARGV.fetch(0))
AegisRelease.real_path!(directory)
FileUtils.mkdir_p(directory, mode: 0o700)
token = Spaceship::ConnectAPI::Token.create(**AegisRelease::BuildStatus.token_options)
api = AegisRelease::AscApi.new(token: token, read_only: true)
names = JSON.parse(ENV.fetch('AEGIS_IOS_PROFILES'))
AegisRelease.require!(names.keys.sort == AegisRelease::IOS_TARGETS.values.sort, 'Exactly three Aegis profiles required')
rows = api.collection('profiles', 'filter[name]' => names.values.join(','), 'include' => 'bundleId', 'limit' => '200')
bundles = rows.fetch('included').select { |item| item['type'] == 'bundleIds' }.to_h { |item| [item.fetch('id'), item] }
files = {'com.gcsa.aegis' => 'Aegis-AppStore-App.mobileprovision',
         'com.gcsa.aegis.safari' => 'Aegis-AppStore-Safari.mobileprovision',
         'com.gcsa.aegis.share' => 'Aegis-AppStore-Share.mobileprovision'}
selected = names.map do |identifier, name|
  matches = rows.fetch('data').select do |item|
    attributes = item.fetch('attributes')
    bundle = bundles.fetch(item.dig('relationships', 'bundleId', 'data', 'id'))
    attributes['name'] == name && attributes['profileType'] == 'IOS_APP_STORE' &&
      attributes['profileState'] == 'ACTIVE' && bundle.dig('attributes', 'identifier') == identifier
  end
  AegisRelease.require!(matches.size == 1, "Unique active App Store profile required for #{identifier}")
  item = matches.first
  attributes = item.fetch('attributes')
  path = File.join(directory, files.fetch(identifier))
  raw = Base64.strict_decode64(attributes.fetch('profileContent'))
  if File.exist?(path)
    AegisRelease.require!(File.binread(path) == raw, 'Profile changed; preserve the old receipt and select a new state directory')
  else
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(raw) }
  end
  {'applicationId' => identifier, 'id' => item.fetch('id'), 'name' => name,
   'uuid' => attributes.fetch('uuid'), 'file' => files.fetch(identifier),
   'sha256' => Digest::SHA256.hexdigest(raw),
   'bundleDisplayName' => bundles.fetch(item.dig('relationships', 'bundleId', 'data', 'id')).dig('attributes', 'name')}
end
puts JSON.pretty_generate('readOnly' => true, 'source' => 'App Store Connect API', 'profiles' => selected)
