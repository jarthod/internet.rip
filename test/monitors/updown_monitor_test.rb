require "test_helper"

class UpdownMonitorTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
    @response = {
      "total" => 100,
      "failing" => 9,
      "points" => [
        { "lat" => 48.0, "lng" => 2.0, "count" => 7 },
        { "lat" => 40.0, "lng" => -74.0, "count" => 2 },
      ],
      "top_isps" => [
        { "isp" => "OVH SAS", "down" => 4, "total" => 6, "rate" => 0.667,
          "spark" => [0.1, nil, 0.2] },
      ],
    }
    response = @response
    UpdownMonitor.define_method(:get_json) { |_url, headers:, **|
      raise "missing auth header" unless headers["X-Internet-Rip-Token"]
      response
    }
  end

  teardown do
    UpdownMonitor.remove_method(:get_json) # falls back to BaseMonitor's real implementation
  end

  test "parses points and top ISPs, and computes the global failure rate" do
    UpdownMonitor.refresh!

    data = UpdownMonitor.snapshot.data
    assert_equal 2, data[:points].size
    assert_equal 100, data[:total]
    assert_equal 9, data[:failing]
    assert_equal 0.09, data[:rate]

    ovh = data[:top_isps].first
    assert_equal "OVH SAS", ovh[:name]
    assert_equal 0.667, ovh[:rate]
    assert_equal [0.1, nil, 0.2], ovh[:spark]
  end

  test "drops points missing lat/lng" do
    @response["points"] = [
      { "lat" => 48.0, "lng" => 2.0, "count" => 1 },
      { "lat" => nil, "lng" => 2.0, "count" => 1 },
    ]

    UpdownMonitor.refresh!

    data = UpdownMonitor.snapshot.data
    assert_equal 1, data[:points].size
  end

  test "an empty/malformed response doesn't crash the monitor" do
    UpdownMonitor.define_method(:get_json) { |_url, **| {} }

    UpdownMonitor.refresh!

    snapshot = UpdownMonitor.snapshot
    assert snapshot.ok?
    assert_equal [], snapshot.data[:points]
    assert_equal [], snapshot.data[:top_isps]
    assert_nil snapshot.data[:rate]
  end
end
