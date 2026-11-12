# frozen_string_literal: true
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "psych"
require "rbconfig"
require "time"
require "uri"

module AegisRelease
  ROOT = File.expand_path("../..", __dir__)
  REPOSITORY = "gcsagroup/aegis-browser"
  APP_ID = "com.gcsa.aegis"
  IOS_TARGETS = { "Aegis" => APP_ID, "SafariWebExtension" => "#{APP_ID}.safari", "ShareExtension" => "#{APP_ID}.share" }.freeze
  DESTINATIONS = {
    'ios' => %w[artifacts testflight testflight-internal testflight-external asc app-store github-draft],
  }.freeze
  ALPHA_DESTINATIONS = {
    'ios' => %w[artifacts testflight testflight-internal github-draft],
  }.freeze
  class Error < StandardError; end

  def self.destinations(platform, profile)
    (profile == 'alpha' ? ALPHA_DESTINATIONS : DESTINATIONS).fetch(platform)
  end

  def self.require!(condition, message)
    raise Error, message unless condition
  end

  # Capture failures without echoing credential-bearing command output or arguments.
  def self.command(executable, *arguments, cwd: ROOT, env: {}, binary: false)
    # Ruby's [executable, argv0] form always uses exec, including zero arguments.
    # Metacharacters therefore remain literal bytes and never select a shell.
    stdout, stderr, status = Open3.capture3({ 'PYTHONDONTWRITEBYTECODE' => '1' }.merge(env),
                                           [executable, executable], *arguments, chdir: cwd, binmode: binary)
    unless status.success?
      detail = [stdout, stderr].compact.map { |chunk| chunk.to_s.strip }.reject(&:empty?).last
      detail = detail.lines.map(&:strip).reject(&:empty?).last if detail
      if detail && detail.length <= 300 && !detail.match?(/PRIVATE KEY|BEGIN |password|P12|AuthKey_/i)
        require!(false, "#{File.basename(executable)} failed (exit #{status.exitstatus}); #{detail}")
      end
      require!(false, "#{File.basename(executable)} failed (exit #{status.exitstatus}); no success receipt written")
    end
    binary ? stdout : stdout.strip
  end

  def self.source(root = ROOT, clean: true)
    status = command("git", "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none", cwd: root)
    require!(!clean || status.empty?, "Release requires a clean committed source; commit changes first")
    { "sha" => command("git", "rev-parse", "HEAD", cwd: root),
      "tree" => command("git", "rev-parse", "HEAD^{tree}", cwd: root), "dirty" => !status.empty? }
  end

  def self.real_path!(path)
    expanded = File.expand_path(path)
    cursor = Pathname.new(expanded)
    loop do
      require!(!cursor.symlink?, "Symlink is not allowed in release paths: #{cursor}")
      break if cursor.root?
      cursor = cursor.parent
    end
    expanded
  end

  def self.file!(path)
    real_path!(path)
    require!(File.file?(path) && File.size(path).positive?, "Missing or empty release file: #{path}")
    path
  end

  def self.digest(path)
    Digest::SHA256.file(file!(path)).hexdigest
  end

  def self.write_new(path, object)
    real_path!(path)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(JSON.pretty_generate(object) + "\n") }
  end

  class Request
    attr_reader :platform, :destination, :version, :build, :run_id, :tag, :root, :expected_digest,
                :profile, :groups, :format, :repository, :input, :timeout, :interval, :signing_mode

    def initialize(platform, options = {}, root: ROOT)
      @root = root
      @platform = platform
      AegisRelease.require!(platform == 'ios', 'Platform must be ios for this release entrypoint')
      unknown = options.keys.map(&:to_sym) - %i[destination version build run_id tag manifest_sha256 profile groups format repository input timeout interval signing_mode]
      AegisRelease.require!(unknown.empty?, "Unknown release options: #{unknown.join(', ')}")
      options = options.transform_keys(&:to_sym)
      @signing_mode = options.fetch(:signing_mode, 'cloud').to_s
      AegisRelease.require!(%w[manual cloud].include?(signing_mode), 'Signing mode must be manual or cloud')
      @input = options[:input]&.to_s
      @timeout = Integer(options.fetch(:timeout, 1800).to_s, exception: false)
      @interval = Integer(options.fetch(:interval, 15).to_s, exception: false)
      AegisRelease.require!(@timeout && (1..3600).cover?(@timeout) && @interval && (1..60).cover?(@interval), 'Invalid wait bounds')
      @destination = options.fetch(:destination, "artifacts").to_s
      AegisRelease.require!(DESTINATIONS.fetch(platform).include?(destination), "Unsupported destination for #{platform}: #{destination}")
      @profile = options.fetch(:profile, 'alpha').to_s.downcase
      AegisRelease.require!(%w[alpha beta release].include?(profile), 'Profile must be alpha, beta or release')
      AegisRelease.require!(AegisRelease.destinations(platform, profile).include?(destination), 'Alpha packages support internal testing only; use a new beta or release package for external distribution')
      AegisRelease.require!(!%w[asc app-store].include?(destination) || profile == 'release', 'Store production destinations require --profile release')
      @groups = options.fetch(:groups, '').to_s.split(',').map(&:strip)
      AegisRelease.require!(groups.uniq == groups && groups.all? { |g| !g.empty? && g.size <= 100 && !g.match?(/[\x00-\x1f]/) }, 'Invalid or duplicate TestFlight groups')
      AegisRelease.require!(groups.empty? || %w[testflight-internal testflight-external].include?(destination), '--groups requires a TestFlight distribution destination')
      @format = options.fetch(:format, 'ipa').to_s
      AegisRelease.require!(format == 'ipa', 'iOS requires an IPA package')
      @repository = options.fetch(:repository, REPOSITORY).to_s
      AegisRelease.require!(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/.match?(repository), 'Invalid GitHub repository')
      AegisRelease.require!(!options[:repository] || destination == 'github-draft', '--repository is only for GitHub Draft')
      native_version, native_build = native_identity
      @version = options.fetch(:version, native_version).to_s
      @build = options.fetch(:build, native_build).to_s
      pattern = /\A\d+\.\d+(?:\.\d+)?\z/
      AegisRelease.require!(pattern.match?(version) && version.size < 40, "Invalid product version")
      AegisRelease.require!(/\A[1-9]\d{0,9}\z/.match?(build), "Build must be a positive integer")
      @run_id = options.fetch(:run_id, "#{profile}-#{version}-#{build}-#{AegisRelease.source(root, clean: false)['sha'][0, 12]}").to_s
      AegisRelease.require!(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}\z/.match?(run_id) && !run_id.include?(".."), "Unsafe run ID")
      @tag = options[:tag]&.to_s
      if destination == "github-draft"
        AegisRelease.require!(tag && /\Acandidate\/#{platform}\/[A-Za-z0-9][A-Za-z0-9_.-]{0,95}\z/.match?(tag) && !tag.include?(".."), "GitHub Draft requires --tag candidate/#{platform}/<version-build>")
      else
        AegisRelease.require!(tag.nil?, "--tag is only supported for github-draft")
      end
      if tag
        expected_tag = "candidate/ios/#{version}-#{profile}.#{build}"
        AegisRelease.require!(tag == expected_tag, 'Candidate tag identity must match version, profile and build')
      end
      @expected_digest = options[:manifest_sha256]&.to_s
      AegisRelease.require!(!expected_digest || /\A[0-9a-f]{64}\z/.match?(expected_digest), "Invalid manifest SHA-256")
    end

    def native_identity
      # Read scalar text, not YAML-coerced floats (1.10 must not become 1.1).
      # Psych's syntax tree never constructs tagged objects or expands aliases.
      stream = Psych.parse_stream(File.read(File.join(root, 'apps/ios/project.yml')))
      AegisRelease.require!(stream.children.length == 1, 'Expected one native project YAML document')
      project = stream.children.first.root
      settings = native_yaml_value(project, 'settings')
      flat_version = native_yaml_value(project, 'MARKETING_VERSION')
      flat_build = native_yaml_value(project, 'CURRENT_PROJECT_VERSION')
      if settings
        AegisRelease.require!(!flat_version && !flat_build, 'Ambiguous native project identity')
        base = native_yaml_value(settings, 'base')
        version_node = native_yaml_value(base, 'MARKETING_VERSION')
        build_node = native_yaml_value(base, 'CURRENT_PROJECT_VERSION')
      else
        version_node, build_node = flat_version, flat_build
      end
      [native_scalar(version_node), native_scalar(build_node)]
    rescue Psych::Exception => e
      raise Error, "Invalid native project YAML: #{e.class}"
    end

    def native_yaml_value(node, key)
      AegisRelease.require!(node.is_a?(Psych::Nodes::Mapping), 'Expected native project settings mapping')
      pairs = node.children.each_slice(2).to_a
      AegisRelease.require!(pairs.all? { |k, _| k.is_a?(Psych::Nodes::Scalar) }, 'Invalid native project mapping key')
      matches = pairs.select { |k, _| k.value == key }
      AegisRelease.require!(matches.length <= 1, "Duplicate native project key: #{key}")
      matches.first&.last
    end

    def native_scalar(node)
      AegisRelease.require!(node.is_a?(Psych::Nodes::Scalar) &&
                           [nil, 'tag:yaml.org,2002:str', 'tag:yaml.org,2002:int', 'tag:yaml.org,2002:float'].include?(node.tag),
                           'Expected native identity scalar')
      node.value
    end

    private :native_yaml_value, :native_scalar

    def directory
      File.join(root, ".artifacts/release", platform, run_id)
    end

    def manifest_path
      File.join(directory, "#{platform}-manifest.json")
    end

    def identity
      { "platform" => platform, "applicationId" => APP_ID, "version" => version, "build" => build, "profile" => profile, "format" => format }
    end

    def plan
      identity.merge("destination" => destination, "tag" => tag, "runId" => run_id,
                     "source" => AegisRelease.source(root, clean: false), "output" => directory,
                     "host" => "macOS",
                     "groups" => groups, "repository" => repository,
                     "stages" => %w[package upload wait metadata compliance distribute submit status],
                     "nativeInputsSha256" => AegisRelease.native_inputs_digest(root),
                     "signingMode" => signing_mode, "uploadSubmitsReview" => false, "releaseReady" => false)
    end

    def validate_stage!(stage)
      AegisRelease.require!(%w[plan package upload release wait metadata compliance distribute submit status].include?(stage), 'Unknown release stage')
      if %w[upload release].include?(stage)
        AegisRelease.require!(destination != 'artifacts', 'Upload requires an external destination')
      elsif stage == 'distribute'
        AegisRelease.require!(%w[testflight-internal testflight-external].include?(destination), 'Distribution requires a testing destination')
        AegisRelease.require!(!groups.empty?, 'TestFlight distribution requires explicit groups')
      elsif stage == 'submit'
        AegisRelease.require!(profile == 'release' && destination == 'app-store', 'Review submission requires a release profile and production destination')
      elsif %w[status wait metadata compliance].include?(stage)
        AegisRelease.require!(!%w[artifacts github-draft].include?(destination), 'Status requires an Apple store destination')
      end
    end
  end

  class Receipt
    def self.create(request, paths, source, details = {})
      AegisRelease.require!(AegisRelease.source(request.root) == source, "Source changed during packaging")
      assets = paths.map do |path|
        AegisRelease.file!(path)
        AegisRelease.require!(File.dirname(File.expand_path(path)) == request.directory, "Artifact must be directly inside the release directory")
        { "name" => File.basename(path), "size" => File.size(path), "sha256" => AegisRelease.digest(path) }
      end
      AegisRelease.require!(assets.any? && assets.map { |a| a['name'] }.uniq.length == assets.length, "Missing or duplicate artifacts")
      value = request.identity.merge("schemaVersion" => 1, "repository" => REPOSITORY, "source" => source,
                                     "assets" => assets, "details" => details, "releaseReady" => false,
                                     "createdAt" => Time.now.utc.iso8601)
      AegisRelease.write_new(request.manifest_path, value)
      sha = AegisRelease.digest(request.manifest_path)
      File.write(request.manifest_path + ".sha256", "#{sha}  #{File.basename(request.manifest_path)}\n", mode: "wx")
      sha
    end

    def self.verify(request, expected_digest)
      AegisRelease.require!(expected_digest && AegisRelease.digest(request.manifest_path) == expected_digest, "Release manifest digest mismatch or missing --manifest-sha256")
      checksum = request.manifest_path + '.sha256'
      AegisRelease.file!(checksum)
      AegisRelease.require!(File.read(checksum) == "#{expected_digest}  #{File.basename(request.manifest_path)}\n", 'Manifest checksum sidecar mismatch')
      value = JSON.parse(File.read(request.manifest_path))
      AegisRelease.require!(value['schemaVersion'] == 1 && value['repository'] == REPOSITORY && value['releaseReady'] == false, "Unsupported release manifest")
      AegisRelease.require!(request.identity.all? { |k, v| value[k] == v }, "Release identity differs from requested platform/version/build")
      AegisRelease.require!(value['source'] == AegisRelease.source(request.root), "Package source differs from current clean checkout")
      assets = value['assets']
      AegisRelease.require!(assets.is_a?(Array) && !assets.empty?, "Missing artifacts")
      names = assets.map { |a| a.fetch('name') }
      AegisRelease.require!(names.uniq == names, "Duplicate artifact names")
      assets.each do |asset|
        name = asset['name']
        AegisRelease.require!(name.is_a?(String) && /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/.match?(name) && !name.include?(".."), "Unsafe artifact name")
        path = File.join(request.directory, name)
        AegisRelease.require!(AegisRelease.digest(path) == asset['sha256'] && File.size(path) == asset['size'], "Artifact changed: #{name}")
      end
      suffix = ".#{request.format}"
      AegisRelease.require!(names.count { |n| n.end_with?(suffix) } == 1, "Expected exactly one #{suffix} artifact")
      value
    end
  end

  class Pipeline
    attr_reader :request

    def initialize(request, fastlane)
      @request = request
      @fastlane = fastlane
    end

    def required(name)
      value = ENV[name]
      AegisRelease.require!(value && !value.empty?, "Missing #{name}")
      value
    end

    def run(*argv, env: {})
      AegisRelease.command(*argv, cwd: request.root, env: env)
      true
    end

    def package
      AegisRelease.require!(RbConfig::CONFIG['host_os'].include?('darwin'), 'iOS packaging requires macOS')
      source = AegisRelease.source(request.root)
      admit_source!
      AegisRelease.real_path!(request.directory)
      AegisRelease.require!(!File.exist?(request.directory), 'Attempt already exists; use a new run ID or upload the verified package')
      required('AEGIS_APPLE_TEAM_ID')
      archive_args = cloud_archive_arguments if request.signing_mode == 'cloud'
      if request.signing_mode == 'manual'
        certificate = required('AEGIS_IOS_CERT_SHA1')
        AegisRelease.require!(/\A[0-9A-Fa-f]{40}\z/.match?(certificate), 'Provide AEGIS_IOS_CERT_SHA1')
        ios_profiles
      end
      run('python3', File.join(request.root, 'scripts/release/safari_manifest.py'), File.join(request.root, 'apps/ios/SharedWebExtension'))
      if ENV['GITHUB_ACTIONS'] == 'true'
        run('python3', File.join(request.root, 'scripts/release/ios-durable.py'), 'export-start',
            '--version', request.version, '--build', request.build, '--profile', request.profile)
      end
      FileUtils.mkdir_p(File.dirname(request.directory))
      Dir.mkdir(request.directory, 0o700)
      paths, details = package_ios(archive_args)
      sha = Receipt.create(request, paths, source, details)
      publish_args = request.destination == 'github-draft' ? ['--draft'] : []
      begin
        run('python3', File.join(request.root, 'scripts/release/ios-publish.py'),
            '--directory', request.directory, '--manifest-sha256', sha, *publish_args)
      rescue Error
        warn 'Downloads catalogue copy failed; retain the verified package and rerun ios-publish.py.'
      end
      puts "Manifest SHA-256: #{sha}"
      if ENV['GITHUB_OUTPUT']
        File.open(ENV.fetch('GITHUB_OUTPUT'), 'a') { |f| f.puts("manifest_sha256=#{sha}\nrun_id=#{request.run_id}") }
      end
      sha
    end

    def ios_profiles
      profiles = JSON.parse(required('AEGIS_IOS_PROFILES'))
      AegisRelease.require!(profiles.is_a?(Hash) && profiles.keys.sort == IOS_TARGETS.values.sort && profiles.values.all? { |v| v.is_a?(String) && !v.empty? }, "AEGIS_IOS_PROFILES must name App Store profiles for the app, Safari and Share extensions")
      profiles
    end

    def package_ios(archive_args = nil)
      return package_ios_cloud(archive_args) if request.signing_mode == 'cloud'
      profiles = ios_profiles
      work = File.join(request.directory, 'work')
      firebase_script = File.join(work, 'apps/ios/scripts/firebase_config.py')
      firebase_args = ['--root', File.join(work, 'apps/ios/Firebase'), '--channel', request.profile]
      stage_ios_package(work, firebase_script, firebase_args)
      project = File.join(work, 'apps/ios/Aegis.xcodeproj')
      team = required('AEGIS_APPLE_TEAM_ID')
      @fastlane.update_code_signing_settings(path: project, use_automatic_signing: false,
                                            team_id: team, code_sign_identity: 'Apple Distribution', build_configurations: ['Release'])
      IOS_TARGETS.each do |target, app_id|
        @fastlane.update_code_signing_settings(path: project, use_automatic_signing: false, team_id: team,
                                              targets: [target], build_configurations: ['Release'], profile_name: profiles.fetch(app_id))
      end
      name = "Aegis-#{request.profile}-#{request.version}-#{request.build}-ios.ipa"
      admit_source!
      @fastlane.build_app(project: project, scheme: 'Aegis-Release', configuration: 'Release', clean: true,
                         destination: 'generic/platform=iOS', output_directory: request.directory, output_name: name,
                         archive_path: File.join(work, 'Aegis.xcarchive'), derived_data_path: File.join(work, 'DerivedData'),
                         buildlog_path: File.join(work, 'logs'), export_method: 'app-store',
                         skip_profile_detection: true, disable_package_automatic_updates: true,
                         xcargs: "MARKETING_VERSION=#{request.version} CURRENT_PROJECT_VERSION=#{request.build} AEGIS_FIREBASE_CHANNEL=#{request.profile} AEGIS_ACCESS_RELEASE_CHANNEL=#{request.profile}",
                         export_options: { method: 'app-store-connect', teamID: team, signingStyle: 'manual',
                                           provisioningProfiles: profiles, manageAppVersionAndBuildNumber: false,
                                           testFlightInternalTestingOnly: request.profile == 'alpha' })
      ipa = File.join(request.directory, name)
      run('python3', firebase_script, 'verify-ipa', *firebase_args, '--artifact', ipa)
      run('python3', File.join(request.root, 'scripts/release/verify-ipa.py'), ipa, request.version, request.build, request.profile)
      certificate = required('AEGIS_IOS_CERT_SHA1')
      run('python3', File.join(request.root, 'scripts/release/verify-signed-ios.py'), ipa, request.version, request.build, request.profile,
          '--team', team, '--certificate-sha1', certificate, '--profiles-json', JSON.generate(profiles), '--source-root', request.root)
      paths = [ipa] + Dir.glob(File.join(request.directory, '*.dSYM.zip'))
      [paths, { 'signing' => 'app-store-export', 'signingMode' => 'manual', 'appleTeamId' => team, 'certificateSha1' => certificate.upcase,
                'provisioningProfiles' => profiles, 'testflight' => 'not_uploaded', 'deviceAcceptance' => 'not_verified',
                'testFlightInternalTestingOnly' => request.profile == 'alpha' }]
    end

    def stage_ios_package(work, firebase_script, firebase_args)
      # Copy only committed inputs; ignored local files must not enter the archive.
      tracked = AegisRelease.command('git', 'ls-files', '-z', 'apps/ios', 'scripts/release/ios_embedded_core.py',
                                     'apps/browser/overlay/chrome/browser/resources/aegis/enhancements_shared',
                                     'packages/core/src/agent/contracts/v1/agent-contract-v1.vectors.json', cwd: request.root).split("\0")
      tracked.each do |relative|
        original = File.join(request.root, relative)
        AegisRelease.real_path!(original)
        AegisRelease.require!(File.file?(original), 'Missing tracked iOS input')
        target = File.join(work, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(original, target)
      end
      run('python3', firebase_script, 'stage', *firebase_args)
      run('bash', File.join(request.root, 'scripts/release/prepare-ios-package-core.sh'), work)
    end

    def cloud_archive_arguments
      path = ENV['AEGIS_CLOUD_ARCHIVE_INPUT'].to_s
      digest = ENV['AEGIS_CLOUD_ARCHIVE_MANIFEST_SHA256'].to_s
      return [] if path.empty? && digest.empty?
      AegisRelease.require!(!path.empty? && /\A[0-9a-f]{64}\z/.match?(digest),
                            'Cloud archive requires the original producer job manifest digest')
      path = File.expand_path(path, request.root)
      manifest_path = AegisRelease.file!(File.join(path, 'archive-manifest.json'))
      File.open(manifest_path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        info = file.stat
        AegisRelease.require!(info.file? && info.size.positive? && info.size <= 16 * 1024**2,
                              'Invalid Development archive manifest')
        bytes = file.read(16 * 1024**2 + 1)
        AegisRelease.require!(bytes.bytesize == info.size && Digest::SHA256.hexdigest(bytes) == digest,
                              'Development archive manifest differs from its producer before export allocation')
        begin
          archive_digest = JSON.parse(bytes).fetch('archive_sha256')
        rescue JSON::ParserError, KeyError, TypeError
          raise Error, 'Invalid Development archive manifest'
        end
        AegisRelease.require!(archive_digest.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(archive_digest),
                              'Invalid Development archive ZIP digest')
        archive_path = AegisRelease.file!(File.join(path, 'archive.zip'))
        File.open(archive_path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |archive|
          archive_info = archive.stat
          AegisRelease.require!(archive_info.file? && archive_info.size.positive? && archive_info.size <= 2 * 1024**3,
                                'Invalid Development archive ZIP')
          checksum = Digest::SHA256.new
          total = 0
          while (chunk = archive.read(1024**2))
            total += chunk.bytesize
            AegisRelease.require!(total <= archive_info.size, 'Development archive ZIP changed during verification')
            checksum.update(chunk)
          end
          AegisRelease.require!(total == archive_info.size && checksum.hexdigest == archive_digest,
                                'Development archive ZIP differs from its producer before export allocation')
        end
      end
      ['--archive-input', path, '--archive-manifest-sha256', digest]
    end

    def package_ios_cloud(archive_args = nil)
      runtime = ENV['RUNNER_ENVIRONMENT'].to_s
      AegisRelease.require!(ENV['GITHUB_ACTIONS'] == 'true' && %w[github-hosted self-hosted].include?(runtime) &&
                            ENV['RUNNER_OS'] == 'macOS',
                            'Cloud production packaging requires a GitHub Actions macOS runner; use the explicit local fallback separately')
      archive_args ||= cloud_archive_arguments
      source = AegisRelease.source(request.root)
      client = AppleStore.new(request, @fastlane, admission: method(:preflight_upload)).tap(&:authenticate)
      before = CloudReservations.preflight(client, request, source)
      engine_run_id = 'production-' + Digest::SHA256.hexdigest(request.run_id)[0,32]
      run('python3', File.join(request.root, 'scripts/release/cloud-signing-poc.py'), '--signing-mode', 'cloud',
          '--runtime', runtime, '--profile', request.profile, '--version', request.version, '--build', request.build,
          '--team', required('AEGIS_APPLE_TEAM_ID'), '--run-id', engine_run_id, *archive_args)
      root = File.join(request.root, '.artifacts/cloud-signing-poc', engine_run_id)
      receipt_path = File.join(root, 'poc-receipt.json')
      receipt = JSON.parse(File.read(AegisRelease.file!(receipt_path)))
      AegisRelease.require!(receipt['status'] == 'ipa_verified' && receipt['signingMode'] == 'cloud' &&
                            receipt['source'] == AegisRelease.source(request.root).reject { |key, _| key == 'dirty' } &&
                            receipt.values_at('profile', 'version', 'build') == [request.profile, request.version, request.build] &&
                            receipt['distributionP12Imported'] == false && receipt['keychainRestored'] == true,
                            'Cloud package receipt differs from requested source/identity')
      assets = receipt.fetch('assets')
      AegisRelease.require!(assets.is_a?(Array) && assets.size == 4 && assets.map { |a| a['name'] }.uniq.size == 4,
                            'Cloud receipt must include IPA, dSYM and verification evidence')
      paths = assets.map do |asset|
        name = asset.fetch('name')
        AegisRelease.require!(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/.match?(name) && !name.include?('..'), 'Unsafe cloud asset name')
        original = File.join(root, name)
        AegisRelease.require!(AegisRelease.digest(original) == asset.fetch('sha256') && File.size(original) == asset.fetch('size'),
                              'Cloud asset differs from verified receipt')
        target = File.join(request.directory, name)
        FileUtils.cp(original, target)
        target
      end
      target_receipt = File.join(request.directory, 'cloud-package-receipt.json')
      FileUtils.cp(receipt_path, target_receipt)
      paths << target_receipt
      reservation = File.join(request.directory, 'cloud-upload-reservation.json')
      AegisRelease.write_new(reservation, CloudReservations.capture(client, request, source, before))
      paths << reservation
      [paths, { 'signing' => 'cloud-app-store-export', 'signingMode' => 'cloud', 'appleTeamId' => receipt.fetch('team'),
                'cloudVerification' => 'signature-verification.json', 'cloudReservation' => 'cloud-upload-reservation.json', 'testflight' => 'not_uploaded',
                'deviceAcceptance' => 'not_verified', 'testFlightInternalTestingOnly' => request.profile == 'alpha' }]
    end

    def upload(expected_digest = request.expected_digest)
      receipt = Receipt.verify(request, expected_digest)
      preflight_upload
      if request.destination == 'github-draft'
        result = Draft.new(request, receipt, expected_digest, admission: method(:preflight_upload)).upload
        AegisRelease.write_new(File.join(request.directory, 'github-upload-result.json'), result)
      else
        asset = receipt.fetch('assets').find { |a| a['name'].end_with?('.ipa') }
        path = File.join(request.directory, asset.fetch('name'))
        run('python3', File.join(request.root, 'scripts/release/verify-ipa.py'), path, request.version, request.build, request.profile)
        details = receipt.fetch('details')
        verification_args = ['--team', details.fetch('appleTeamId'), '--source-root', request.root]
        if details.fetch('signingMode', 'manual') == 'cloud'
          verification_args += ['--signing-mode', 'cloud', '--expected-verification', File.join(request.directory, details.fetch('cloudVerification'))]
        else
          verification_args += ['--certificate-sha1', details.fetch('certificateSha1'), '--profiles-json', JSON.generate(details.fetch('provisioningProfiles'))]
        end
        run('python3', File.join(request.root, 'scripts/release/verify-signed-ios.py'), path, request.version, request.build, request.profile, *verification_args)
        client = store
        client.authenticate
        result = Journal.new(request, expected_digest).perform('apple-upload') do
          if details.fetch('signingMode', 'manual') == 'cloud'
            proof = JSON.parse(File.read(AegisRelease.file!(File.join(request.directory, details.fetch('cloudReservation')))))
            client.upload(path, cloud_reservations: proof, source: receipt.fetch('source'))
          else
            client.upload(path)
          end
        end
      end
      puts JSON.pretty_generate(result)
      result
    end

    def preflight_upload
      AegisRelease.require!(request.destination != 'artifacts', 'Choose an upload destination')
      admit_source!
    end

    def admit_source!
      sha = AegisRelease.source(request.root).fetch('sha')
      run('node', File.join(request.root, 'scripts/ci/ios-release-preflight.mjs'), '--sha', sha,
            env: { 'RELEASE_DESTINATION' => request.destination, 'RELEASE_TAG' => request.tag })
    end

    def store
      AegisRelease.require!(!%w[artifacts github-draft].include?(request.destination), 'Choose an Apple store destination')
      authorize_operator!
      AppleStore.new(request, @fastlane, admission: method(:preflight_upload))
    end

    def authorize_operator!
      run('node', File.join(request.root, 'scripts/ci/ios-operator.mjs'), '--context', 'delivery')
    end

    def status
      client = store
      client.authenticate
      result = request.identity.merge('destination' => request.destination, 'remote' => client.status)
      if File.directory?(request.directory)
        result['localStages'] = Dir.glob(File.join(request.directory, '*-{started,result}.json')).map do |path|
          { 'file' => File.basename(path), 'record' => JSON.parse(File.read(AegisRelease.file!(path))) }
        end
      end
      puts JSON.pretty_generate(result)
      result
    end

    def distribute
      request.validate_stage!('distribute')
      store_stage('distribute') { |client, _input, groups| client.distribute(groups) }
    end

    def submit
      request.validate_stage!('submit')
      store_stage('submit') { |client| client.submit }
    end

    def wait
      client = store
      client.authenticate
      result = client.wait_for_processing(timeout: request.timeout, interval: request.interval)
      puts JSON.pretty_generate(result)
      result
    end

    def metadata
      store_stage('metadata') { |client, value| client.metadata(value) }
    end

    def compliance
      store_stage('compliance') { |client, value| client.compliance(value) }
    end

    def read_input(stage)
      return nil unless %w[metadata compliance].include?(stage)
      AegisRelease.require!(request.input, 'This stage requires --input JSON file')
      path = AegisRelease.file!(File.expand_path(request.input))
      AegisRelease.require!(File.size(path) <= 64_000, 'Stage input file too large')
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      raise Error, 'Invalid stage JSON input'
    end

    def store_stage(stage)
      Receipt.verify(request, request.expected_digest)
      uploaded = JSON.parse(File.read(AegisRelease.file!(File.join(request.directory, 'apple-upload-result.json'))))
      intent = uploaded.fetch('intent')
      AegisRelease.require!(intent['manifestSha256'] == request.expected_digest && request.identity.all? { |k, v| intent[k] == v },
                            'Store mutation requires the completed upload record for this exact package')
      value = read_input(stage)
      preflight_upload
      client = store
      client.validate_metadata!(value) if stage == 'metadata'
      client.validate_compliance!(value) if stage == 'compliance'
      client.authenticate
      client.wait_for_processing if ENV['GITHUB_ACTIONS'] == 'true'
      %w[compliance metadata].include?(stage) ? client.processed_build : client.ready_build
      selected = stage == 'distribute' ? client.groups : []
      parameters = { 'destination' => request.destination, 'groupIds' => selected.map { |g| g.fetch('id') },
                     'inputSha256' => value && Digest::SHA256.hexdigest(JSON.generate(value)) }
      result = Journal.new(request, request.expected_digest).perform("ios-#{stage}", parameters) { yield client, value, selected }
      puts JSON.pretty_generate(result)
      result
    end
  end

  class Draft
    def initialize(request, receipt, expected_digest, environment: ENV, admission: nil)
      @request, @receipt, @expected_digest, @environment, @admission = request, receipt, expected_digest, environment, admission
    end

    def gh(*args)
      AegisRelease.command('gh', *args)
    end

    def api(path)
      JSON.parse(gh('api', "repos/#{@request.repository}/#{path}", '--header', 'Cache-Control: no-cache'))
    end

    def releases
      JSON.parse(gh('api', "repos/#{@request.repository}/releases?per_page=100", '--paginate', '--slurp')).flatten(1)
    end

    def selected
      matches = releases.select { |r| r['tag_name'] == @request.tag }
      AegisRelease.require!(matches.size <= 1, 'Multiple releases for candidate tag')
      matches.first && validate_release(matches.first)
    end

    def validate_release(value)
      AegisRelease.require!(value.is_a?(Hash) && value['id'].is_a?(Integer) && value['id'].positive? &&
                            value['tag_name'] == @request.tag, 'Release response differs from the candidate tag')
      AegisRelease.require!(value['draft'] == true && value['prerelease'] == true, 'Existing release must remain a candidate draft')
      AegisRelease.require!(value['target_commitish'] == @receipt['source']['sha'], 'Existing draft targets a different source')
      value
    end

    def refresh(release)
      current = validate_release(api("releases/#{release.fetch('id')}"))
      AegisRelease.require!(current['id'] == release['id'], 'Release ID changed')
      current
    end

    def expected_assets
      @receipt.fetch('assets') + [@request.manifest_path, @request.manifest_path + '.sha256'].map do |path|
        { 'name' => File.basename(path), 'sha256' => AegisRelease.digest(path), 'size' => File.size(path) }
      end
    end

    def check_assets(release, complete: false)
      remote = api("releases/#{Integer(release.fetch('id'))}/assets?per_page=100")
      expected = expected_assets.to_h { |a| [a.fetch('name'), a] }
      names = remote.map { |a| a.fetch('name') }
      AegisRelease.require!(names.uniq == names && (names - expected.keys).empty?, 'Unexpected or duplicate draft assets')
      remote.each do |asset|
        local = expected.fetch(asset.fetch('name'))
        AegisRelease.require!(asset['state'] == 'uploaded' && asset['size'] == local['size'] && asset['digest'] == "sha256:#{local['sha256']}", "Existing draft asset differs: #{asset['name']}; never overwrite")
      end
      AegisRelease.require!(!complete || names.sort == expected.keys.sort, 'Draft is missing assets')
      if complete
        remote.each do |asset|
          bytes = fetch_asset_bytes(asset)
          local = expected.fetch(asset.fetch('name'))
          AegisRelease.require!(bytes.bytesize == local['size'] && Digest::SHA256.hexdigest(bytes) == local['sha256'], 'Downloaded Draft asset bytes differ from manifest')
        end
      end
      names
    end

    def fetch_asset_bytes(asset)
      id = Integer(asset.fetch('id'))
      AegisRelease.require!(id.positive?, 'Draft asset ID must be positive')
      AegisRelease.command('gh', 'api', "repos/#{@request.repository}/releases/assets/#{id}",
                           '--header', 'Accept: application/octet-stream', cwd: @request.root, binary: true)
    end

    def upload
      Receipt.verify(@request, @expected_digest)
      sha = @receipt.fetch('source').fetch('sha')
      tag = URI.encode_www_form_component(@request.tag)
      AegisRelease.require!(api("commits/#{tag}")['sha'] == sha, 'Existing upstream candidate tag must resolve to the exact package commit')
      parameters = { 'repository' => @request.repository, 'tag' => @request.tag }
      journal = Journal.new(@request, @expected_digest)
      created = File.join(@request.directory, 'github-draft-create-result.json')
      release = if File.exist?(created)
                  journal.perform('github-draft-create', parameters) { raise Error, 'Missing completed draft creation record' }
                else
                  selected
                end
      unless release
        AegisRelease.require!(@environment['GITHUB_ACTIONS'] != 'true' || @environment['GITHUB_RUN_ATTEMPT'] == '1',
          'Actions rerun cannot create another draft; reconcile the earlier release or retained creation record')
        notes = File.join(@request.directory, 'draft-notes.txt')
        text = "Candidate package: #{@request.platform} #{@request.profile} #{@request.version} (#{@request.build})\n\nSource: #{sha}\nSigning: #{@receipt.fetch('details').fetch('signing')}\nDevice acceptance: not verified. Distribution qualification: not complete.\n"
        AegisRelease.real_path!(notes)
        if File.exist?(notes)
          AegisRelease.require!(File.read(notes) == text, 'Existing draft notes differ; retain the previous attempt')
        else
          File.write(notes, text, mode: 'wx')
        end
        Receipt.verify(@request, @expected_digest)
        payload = { 'tag_name' => @request.tag, 'target_commitish' => sha, 'draft' => true, 'prerelease' => true,
                    'name' => "Aegis #{@request.platform} #{@request.profile} #{@request.version} (#{@request.build}) candidate", 'body' => text }
        input = File.join(@request.directory, 'draft-request.json')
        AegisRelease.real_path!(input)
        if File.exist?(input)
          AegisRelease.require!(JSON.parse(File.read(AegisRelease.file!(input))) == payload, 'Existing draft request differs')
        else
          AegisRelease.write_new(input, payload)
        end
        release = journal.perform('github-draft-create', parameters) do
          AegisRelease.require!(api("commits/#{tag}")['sha'] == sha, 'Candidate tag changed before draft creation')
          @admission&.call
          validate_release(JSON.parse(gh('api', "repos/#{@request.repository}/releases", '--method', 'POST', '--input', input)))
        end
      end
      release = refresh(validate_release(release))
      present = check_assets(release)
      expected_assets.each do |asset|
        next if present.include?(asset['name'])
        AegisRelease.require!(asset['size'] < 2 * 1024**3, 'GitHub asset must be smaller than 2 GiB')
        Receipt.verify(@request, @expected_digest)
        refresh(release) # Check the known ID before sending the next asset.
        @admission&.call
        gh('release', 'upload', @request.tag, File.join(@request.directory, asset['name']), '--repo', @request.repository)
      end
      release = refresh(release)
      AegisRelease.require!(api("commits/#{tag}")['sha'] == sha, 'Candidate tag changed during upload')
      Receipt.verify(@request, @expected_digest)
      check_assets(release, complete: true)
      { 'status' => 'draft_assets_verified', 'url' => release.fetch('html_url'), 'source' => @receipt['source'],
        'tag' => @request.tag, 'draft' => true, 'releaseReady' => false }
    end
  end
end

require_relative "stores"

require_relative 'ios_lifecycle'
