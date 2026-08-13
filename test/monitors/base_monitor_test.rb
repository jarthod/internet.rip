require "test_helper"

class BaseMonitorTest < ActiveSupport::TestCase
  # A network-free monitor so the framework can be tested in isolation.
  class DummyMonitor < BaseMonitor
    self.interval = 30
    cattr_accessor :boom, default: false

    def fetch
      raise "boom" if DummyMonitor.boom
      { value: 42 }
    end
  end

  setup do
    Rails.cache.clear
    DummyMonitor.boom = false
  end

  test "a cold snapshot reports as loading" do
    assert DummyMonitor.snapshot.loading?
    assert_nil DummyMonitor.snapshot.data
  end

  test "refresh! fetches and caches the data" do
    DummyMonitor.refresh!
    snapshot = DummyMonitor.snapshot
    assert snapshot.ok?
    assert_not snapshot.loading?
    assert_equal 42, snapshot.data[:value]
  end

  test "refresh! records the error but keeps the last good data" do
    DummyMonitor.refresh!            # cache good data first
    DummyMonitor.boom = true
    DummyMonitor.refresh!            # now the source fails

    snapshot = DummyMonitor.snapshot
    assert_not snapshot.ok?
    assert_match "boom", snapshot.error
    assert_equal 42, snapshot.data[:value], "stale data should be retained on failure"
  end

  test "stale? honours the configured interval" do
    Rails.cache.write(DummyMonitor.cache_key, { data: {}, updated_at: 1.hour.ago, error: nil })
    assert DummyMonitor.snapshot.stale?(DummyMonitor.interval)

    Rails.cache.write(DummyMonitor.cache_key, { data: {}, updated_at: Time.current, error: nil })
    assert_not DummyMonitor.snapshot.stale?(DummyMonitor.interval)
  end

  test "every monitor is registered" do
    assert_includes BaseMonitor.registry, RootServersMonitor
    assert_includes BaseMonitor.registry, OutagesMonitor
    assert_includes BaseMonitor.registry, GripMonitor
    assert_includes BaseMonitor.registry, PublicResolversMonitor
  end
end
