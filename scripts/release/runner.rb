# frozen_string_literal: true

require 'json'

ready = ENV.fetch('ANDROID_RUNNERS_READY', '')
arch = ENV.fetch('AEGIS_ANDROID_RUNNER_ARCH', '')
experimental = ENV.fetch('AEGIS_ANDROID_EXPERIMENTAL_ARM64', '')
abort 'Android release runners are not marked ready' unless ready == 'true'

labels = case arch
         when 'x64'
           %w[self-hosted Linux X64 aegis-android-linux-x64]
         when 'arm64'
           abort 'Android ARM64 runners are experimental' unless experimental == 'true'
           %w[self-hosted Linux ARM64 aegis-android-linux-arm64]
         else
           abort 'Android runner architecture must be x64 or arm64'
         end
puts "runner=#{labels.to_json}"
