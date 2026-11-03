# frozen_string_literal: true
require_relative 'release'
require 'base64'

module AegisRelease
  # Lookup identity is deliberately independent of package profiles and retained artifacts.
  class BuildStatus
    def self.token_options(environment = ENV)
      names = %w[AEGIS_ASC_KEY_ID AEGIS_ASC_ISSUER_ID AEGIS_ASC_KEY_BASE64]
      AegisRelease.require!(names.all? { |name| environment[name].is_a?(String) && !environment[name].strip.empty? },
                            'ASC credentials missing; verify explicit reusable-workflow forwarding and protected environment')
      key = Base64.strict_decode64(environment.fetch('AEGIS_ASC_KEY_BASE64'))
      AegisRelease.require!(!key.empty?, 'ASC key encoding is empty')
      { key_id: environment.fetch('AEGIS_ASC_KEY_ID'), issuer_id: environment.fetch('AEGIS_ASC_ISSUER_ID'), key: key }
    rescue ArgumentError
      raise Error, 'ASC key encoding is invalid'
    end

    Identity = Struct.new(:version, :build, keyword_init: true)

    def initialize(version:, build:, api:)
      AegisRelease.require!(version.is_a?(String) && /\A[0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?\z/.match?(version) &&
                            build.is_a?(String) && /\A[1-9][0-9]{0,9}\z/.match?(build),
                            'Enter a valid version and build number')
      @identity, @api = Identity.new(version: version, build: build), api
    end

    def call
      apps = @api.collection('apps', 'filter[bundleId]' => APP_ID).fetch('data')
      AegisRelease.require!(apps.size == 1 && apps.first.dig('attributes', 'bundleId') == APP_ID,
                            'Unique ASC application required for the exact bundle ID')
      app_id = apps.first.fetch('id')
      remote = AppleStore.new(@identity, nil, api: @api, app_id: app_id).status
      { 'platform' => 'ios', 'applicationId' => APP_ID, 'version' => @identity.version, 'build' => @identity.build,
        'readOnly' => true, 'packageProvenanceVerified' => false, 'remote' => remote }
    end
    def wait(timeout: 300, interval: 15, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) })
      AegisRelease.require!((1..300).cover?(timeout) && (1..30).cover?(interval), 'Invalid read-only wait bounds')
      deadline = clock.call + timeout
      loop do
        value = call
        remote = value.fetch('remote')
        AegisRelease.require!(!remote.fetch('uploadState').split(',').include?('FAILED') &&
                              !%w[FAILED INVALID].include?(remote.fetch('processingState')),
                              'Apple rejected this build/upload; inspect status without reuploading')
        if remote['processingState'] == 'VALID'
          AegisRelease.require!(remote['expired'] == false, 'Exact build is expired')
          return value
        end
        AegisRelease.require!(remote['processingState'] != 'NOT_FOUND' || remote['uploadState'] != 'NOT_FOUND',
                              'Exact version/build has no upload; nothing to wait for')
        remaining = deadline - clock.call
        AegisRelease.require!(remaining.positive?, 'Processing wait timed out; no upload or retry performed')
        sleeper.call([interval, remaining].min)
      end
    end
  end
end
