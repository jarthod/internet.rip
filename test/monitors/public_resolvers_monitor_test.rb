require "test_helper"

class PublicResolversMonitorTest < ActiveSupport::TestCase
  # Stub the PerfOps HTTP call (no network/credentials in tests) while
  # exercising the real fetch/parsing logic.
  PERFOPS_RESPONSE = {
    "result" => [
      { "statFunction" => "MEAN", "data" => [{ "y" => 20.0, "x" => 1 }, { "y" => 18.5, "x" => 2 }] },
      { "statFunction" => "UPTIME", "data" => [{ "y" => 0.999, "x" => 1 }, { "y" => 0.9995, "x" => 2 }] },
    ],
  }.freeze

  setup do
    Rails.cache.clear
    @responses = PublicResolversMonitor::RESOLVERS.values.to_h { |cfg| [cfg[:id], PERFOPS_RESPONSE] }
    responses = @responses
    PublicResolversMonitor.define_method(:get_json) { |url, **| responses.fetch(url[/providers=(\d+)/, 1].to_i) }
  end

  teardown do
    PublicResolversMonitor.remove_method(:get_json) # falls back to BaseMonitor's real implementation
  end

  test "parses the latest latency/uptime and full daily series into a sparkline" do
    PublicResolversMonitor.refresh!

    data = PublicResolversMonitor.snapshot.data
    assert_equal PublicResolversMonitor::RESOLVERS.size, data[:resolvers].size
    google = data[:resolvers].find { _1[:name] == "Google" }
    assert_equal 18.5, google[:ms]       # latest (last) MEAN point
    assert_equal 99.95, google[:uptime]  # latest UPTIME point, as a %
    assert_equal "ok", google[:status]
    assert_equal [20.0, 18.5], google[:spark]
  end

  test "a resolver with degraded uptime is flagged, others unaffected" do
    ip = PublicResolversMonitor::RESOLVERS["OpenDNS"][:id]
    @responses[ip] = {
      "result" => [
        { "statFunction" => "MEAN", "data" => [{ "y" => 40.0, "x" => 1 }] },
        { "statFunction" => "UPTIME", "data" => [{ "y" => 0.92, "x" => 1 }] },
      ],
    }

    PublicResolversMonitor.refresh!

    data = PublicResolversMonitor.snapshot.data
    opendns = data[:resolvers].find { _1[:name] == "OpenDNS" }
    assert_equal "down", opendns[:status]
    assert_equal data[:total] - 1, data[:up]
  end

  test "a failed request for one resolver doesn't take down the others" do
    ip = PublicResolversMonitor::RESOLVERS["Quad9"][:id]
    @responses.delete(ip) # Hash#fetch will raise KeyError for this one

    PublicResolversMonitor.refresh!

    snapshot = PublicResolversMonitor.snapshot
    assert snapshot.ok?, "one resolver's failure shouldn't fail the whole monitor"
    quad9 = snapshot.data[:resolvers].find { _1[:name] == "Quad9" }
    assert_equal "unknown", quad9[:status]
    assert_nil quad9[:ms]
    google = snapshot.data[:resolvers].find { _1[:name] == "Google" }
    assert_equal "ok", google[:status]
  end
end
