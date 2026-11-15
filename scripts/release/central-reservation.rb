# frozen_string_literal: true
require_relative '../../fastlane/lib/ios_status'
require 'spaceship'

# This process receives only the independently approved read-only ASC identity.
operation, prepared_path, output_path = ARGV
AegisRelease.require!(%w[preflight capture].include?(operation), 'Unknown central status operation')
prepared = JSON.parse(File.read(prepared_path))
value = prepared.fetch('request')
identity = Struct.new(:version, :build, :profile).new(value.fetch('version'), value.fetch('build'), 'alpha')
source = value.fetch('source').slice('sha', 'tree')
token = Spaceship::ConnectAPI::Token.create(**AegisRelease::BuildStatus.token_options)
api = AegisRelease::AscApi.new(token: token, read_only: true)
store = AegisRelease::AppleStore.new(identity, nil, api: api, app_id: value.fetch('application'))
if operation == 'preflight'
  proof = AegisRelease::CloudReservations.preflight(store, identity, source)
  AegisRelease.write_new(output_path, proof)
else
  before = JSON.parse(File.read(File.join(File.dirname(prepared_path), 'asc-before.json')))
  proof = AegisRelease::CloudReservations.capture(store, identity, source, before)
  AegisRelease.write_new(output_path, proof)
end
