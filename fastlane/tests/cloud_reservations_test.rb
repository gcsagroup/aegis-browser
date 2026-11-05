# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../lib/release'

class CloudReservationsTest < Minitest::Test
  Store = Struct.new(:records, :files, :build) do
    def status
      {'processingState' => build ? 'VALID' : 'NOT_FOUND', 'uploadState' => records.empty? ? 'NOT_FOUND' : 'AWAITING_UPLOAD',
       'uploads' => records, 'observedAt' => Time.now.utc.iso8601}
    end
    def exact_build = build
    def upload_records = records
    def upload_files(_id) = files
  end

  def setup
    @identity = Struct.new(:version, :build).new('0.8.0', '510')
    @source = {'sha' => 'a' * 40, 'tree' => 'b' * 40}
    @store = Store.new([], [], nil)
    @before = AegisRelease::CloudReservations.preflight(@store, @identity, @source)
  end

  def reservation
    {'type' => 'buildUploads', 'id' => 'b155cd7e-17a1-41a9-9749-6ba2a58b9ea6',
     'attributes' => {'cfBundleShortVersionString' => '0.8.0', 'cfBundleVersion' => '510', 'platform' => 'IOS',
                      'createdDate' => Time.now.utc.iso8601, 'uploadedDate' => nil,
                      'state' => {'state' => 'AWAITING_UPLOAD', 'errors' => []}}}
  end

  def capture
    AegisRelease::CloudReservations.capture(@store, @identity, @source, @before)
  end

  def test_empty_xcode_reservation_is_bound_to_our_unused_build_and_source
    @store.records = [reservation]
    proof = capture
    assert_equal @source, proof.fetch('source')
    assert_equal [@store.records.first['id']], proof.fetch('reservations').map { |r| r['id'] }
    assert AegisRelease::CloudReservations.verify!(@store, @identity, @source, proof)
    assert_raises(AegisRelease::Error) { AegisRelease::CloudReservations.preflight(@store, @identity, @source) }
    assert_raises(AegisRelease::Error) { AegisRelease::CloudReservations.verify!(@store, @identity, @source.merge('sha' => 'c' * 40), proof) }
  end

  def test_upload_activity_missing_or_changed_records_always_block_replay
    @store.records = [reservation]
    proof = capture
    %w[PROCESSING COMPLETE FAILED].each do |state|
      @store.records.first['attributes']['state']['state'] = state
      assert_raises(AegisRelease::Error) { AegisRelease::CloudReservations.verify!(@store, @identity, @source, proof) }
    end
    @store.records = [reservation]
    @store.files = [{'id' => 'already-started-file'}]
    assert_raises(AegisRelease::Error) { AegisRelease::CloudReservations.verify!(@store, @identity, @source, proof) }
    @store.files = []
    @store.records = []
    assert_raises(AegisRelease::Error) { AegisRelease::CloudReservations.verify!(@store, @identity, @source, proof) }
    @store.records = [reservation.merge('id' => 'a155cd7e-17a1-41a9-9749-6ba2a58b9ea6')]
    assert_raises(AegisRelease::Error) { AegisRelease::CloudReservations.verify!(@store, @identity, @source, proof) }
  end

  def test_old_ambiguous_wrong_identity_and_completed_builds_cannot_be_adopted
    @store.records = [reservation]
    @store.records.first['attributes']['createdDate'] = (Time.now - 600).utc.iso8601
    assert_raises(AegisRelease::Error) { capture }
    @store.records = [reservation, reservation]
    assert_raises(AegisRelease::Error) { capture }
    @store.records = [reservation]
    @store.records.first['attributes']['cfBundleVersion'] = '511'
    assert_raises(AegisRelease::Error) { capture }
    @store.records = []
    @store.build = {'id' => 'already-processed'}
    assert_raises(AegisRelease::Error) { capture }
  end

  def test_apple_upload_allows_only_recorded_empty_cloud_reservation_and_preserves_manual_guard
    @store.records = [reservation]
    proof = capture
    pilot_calls = []
    pilot = Object.new
    pilot.define_singleton_method(:upload_to_testflight) { |**options| pilot_calls << options }
    store = AegisRelease::AppleStore.new(@identity, pilot, app_id: 'app')
    fixture = @store
    store.define_singleton_method(:exact_build) { fixture.exact_build }
    store.define_singleton_method(:upload_records) { fixture.upload_records }
    store.define_singleton_method(:upload_files) { |id| fixture.upload_files(id) }
    assert_raises(AegisRelease::Error) { store.upload('fixture.ipa') }
    assert_equal 0, pilot_calls.size
    assert_equal false, store.upload('fixture.ipa', cloud_reservations: proof, source: @source)['reviewSubmitted']
    assert_equal 1, pilot_calls.size
    assert_equal true, pilot_calls.first[:skip_submission]
    @store.files = [{'id' => 'transport-created'}]
    assert_raises(AegisRelease::Error) { store.upload('fixture.ipa', cloud_reservations: proof, source: @source) }
    assert_equal 1, pilot_calls.size
  end
end
