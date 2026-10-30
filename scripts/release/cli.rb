# frozen_string_literal: true
require "optparse"
require "rubygems"
require_relative "../../fastlane/lib/release"

begin
  options = {}
  parser = OptionParser.new do |p|
    p.banner = "Usage: ./release ios <plan|package|upload|release|wait|metadata|compliance|distribute|submit|status> [options]"
    p.on("--profile NAME", "alpha (internal testing only), beta, release") { |v| options[:profile] = v }
    p.on("--destination NAME", "artifacts, testflight[-internal|-external], asc, app-store, github-draft") { |v| options[:destination] = v }
    p.on("--groups NAMES", "Comma-separated existing TestFlight group names") { |v| options[:groups] = v }
    p.on("--format NAME", "ipa") { |v| options[:format] = v }
    p.on("--repository OWNER_REPO", "GitHub Draft repository (default upstream); explicit fork for rehearsal") { |v| options[:repository] = v }
    p.on("--version VERSION", "iOS marketing version") { |v| options[:version] = v }
    p.on("--build NUMBER", "iOS build") { |v| options[:build] = v }
    p.on("--run-id ID", "Unique local attempt directory; reuse only for upload") { |v| options[:run_id] = v }
    p.on("--tag TAG", "Existing candidate/<platform>/... tag for GitHub Draft") { |v| options[:tag] = v }
    p.on("--input PATH", "Explicit metadata/compliance JSON file") { |v| options[:input] = v }
    p.on("--timeout SECONDS", "Wait timeout, 1..3600") { |v| options[:timeout] = v }
    p.on("--interval SECONDS", "Wait poll interval, 1..60") { |v| options[:interval] = v }
    p.on("--manifest-sha256 SHA", "Required for upload of an existing package") { |v| options[:manifest_sha256] = v }
    p.on("-h", "--help") { puts p; exit 0 }
  end
  parser.parse!
  if ARGV.empty? && $stdin.tty?
    choose = lambda do |label, values|
      puts "#{label}: #{values.each_with_index.map { |v, i| "#{i + 1}=#{v}" }.join('  ')}"
      index = Integer($stdin.gets.to_s.strip, exception: false)
      raise ArgumentError, 'Invalid selection' unless index && (1..values.size).cover?(index)
      values[index - 1]
    end
    platform = 'ios'
    options[:profile] = choose.call('Profile', %w[alpha beta release])
    options[:destination] = choose.call('Destination', AegisRelease.destinations(platform, options[:profile]))
    stage = choose.call('Stage', %w[plan package release upload distribute submit status])
    %i[version build run_id].each do |field|
      print "#{field} (Enter = default): "
      value = $stdin.gets.to_s.strip
      options[field] = value unless value.empty?
    end
    if options[:destination] == 'github-draft'
      print 'Existing candidate tag: '
      options[:tag] = $stdin.gets.to_s.strip
    end
    if stage == 'distribute' && platform == 'ios'
      print 'Existing TestFlight group names (comma separated): '
      options[:groups] = $stdin.gets.to_s.strip
    end
    if %w[upload metadata compliance distribute submit].include?(stage)
      print 'Manifest SHA-256 retained from package: '
      options[:manifest_sha256] = $stdin.gets.to_s.strip
    end
    puts JSON.pretty_generate(AegisRelease::Request.new(platform, options).plan.merge('selectedStage' => stage))
    if stage != 'plan' && stage != 'status'
      print "Execute #{stage}? Type #{stage} to continue: "
      raise ArgumentError, 'Cancelled' unless $stdin.gets.to_s.strip == stage
    end
    ARGV.replace([platform, stage])
  end
  raise ArgumentError, parser.to_s unless (1..2).cover?(ARGV.length)
  platform, stage = ARGV
  stage ||= "plan"
  raise ArgumentError, "Unknown stage: #{stage}" unless %w[plan package upload release wait metadata compliance distribute submit status].include?(stage)
  raise ArgumentError, '--profile is required explicitly for mutations' unless %w[plan status wait].include?(stage) || options[:profile]
  request = AegisRelease::Request.new(platform, options)
  request.validate_stage!(stage)
  if stage == "plan"
    puts JSON.pretty_generate(request.plan)
  else
    AegisRelease.require!(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3'), 'Use Ruby 3.3 or newer on PATH, then run bundle install')
    raise ArgumentError, "#{stage} requires --manifest-sha256" if %w[upload metadata compliance distribute submit].include?(stage) && !options[:manifest_sha256]
    raise ArgumentError, "release/upload requires an upload destination" if %w[release upload].include?(stage) && request.destination == "artifacts"
    Dir.chdir(AegisRelease::ROOT)
    ENV["FASTLANE_SKIP_UPDATE_CHECK"] = "1"
    ENV["FASTLANE_HIDE_GITHUB_ISSUES"] = "1"
    ENV["FASTLANE_OPT_OUT_USAGE"] = "1"
    ENV["BUNDLE_GEMFILE"] = File.join(AegisRelease::ROOT, "Gemfile")
    exec("bundle", "exec", "fastlane", platform, stage,
         *options.map { |key, value| "#{key}:#{value}" })
  end
rescue ArgumentError, AegisRelease::Error, OptionParser::ParseError => e
  warn e.message
  exit 1
end
