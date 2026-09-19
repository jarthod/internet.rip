require "test_helper"

class DashboardTest < ActionDispatch::IntegrationTest
  def seed(klass, data)
    Rails.cache.write(klass.cache_key, { data: data, updated_at: Time.current, error: nil })
  end

  # Pre-populate the cache so the monitors aren't stale (no background network
  # refresh is triggered) and the page renders real data.
  setup do
    Rails.cache.clear
    InternetController::PAGE_CACHE.clear
    seed RootServersMonitor,
      { servers: [{ letter: "a", msm_id: 10009, avail: 100, median: 12.3, up: true,
                    spark: [10, 12, 11, 13, 12], url: "https://atlas.ripe.net/measurements/10009/" }],
        up: 1, total: 1, probes: 50 }
    seed ServiceStatusMonitor,
      [{ name: "GitHub", url: "https://x", indicator: "none",
         description: "All Systems Operational", error: nil }]
    seed PublicSitesMonitor,
      { sites: [{ name: "Google", url: "https://google.com", up: true, code: 200, ms: 80, error: nil }],
        up: 1, total: 1 }
    tld_de = { zone: "de", tld: "de", name: "de", cc: "DE", avail: 78.0, median: 22.4, servers: 6,
               status: "down", spark: [80, 79, 78, 77, 78], checked_at: Time.current,
               url: "https://dnsmon.ripe.net/de" }
    seed TldMonitor,
      { zones: { "de" => tld_de }, total: 70, checked: 1, ok: 0, problems: [tld_de] }
    seed OutagesMonitor,
      { countries: [{ code: "BZ", name: "Belize", pct: 100, events: 1, severe: true,
                      reason: "active probing down", reason_full: "active probing + BGP routing down",
                      datasource: "ping-slash24",
                      url: "https://ioda.inetintel.cc.gatech.edu/country/BZ" }],
        count: 1 }
    seed GripMonitor,
      { events: [
          { id: "moas-1-1_2", label: "possible hijack", time: Time.current,
            finished_at: nil, explanation: "test", suspicion: 80, prefixes: ["1.2.3.0/24"],
            countries: %w[US], url: "https://grip.inetintel.cc.gatech.edu/v1/events/moas/moas-1-1_2" },
          { id: "moas-3-3_4", label: "possible hijack", time: 1.hour.ago,
            finished_at: 30.minutes.ago, explanation: "test", suspicion: 80, prefixes: ["5.6.7.0/24"],
            countries: %w[FR], url: "https://grip.inetintel.cc.gatech.edu/v1/events/moas/moas-3-3_4" },
        ] }
    seed PublicResolversMonitor,
      { resolvers: [
          { name: "Cloudflare", url: "https://1.1.1.1/", status: "ok",
            ms: 8, uptime: 99.98, spark: [8, 9, 7, 8] },
          { name: "Google", url: "https://developers.google.com/speed/public-dns",
            status: "down", ms: 40, uptime: 92.1, spark: [10, 11, 40] },
        ], up: 1, total: 2 }
    seed UpdownMonitor,
      { points: [
          { lat: 48.0, lng: 2.0, count: 7 },
          { lat: 40.0, lng: -74.0, count: 2 },
        ],
        top_isps: [
          { name: "OVH SAS", down: 4, total: 6, rate: 0.667, spark: [0.1, nil, 0.2] },
        ],
        total: 100, failing: 9, rate: 0.09 }
  end

  test "the dashboard renders with the map and all panels" do
    get root_path
    assert_response :success
    assert_select "figure.map"
    assert_select "svg.grid"                 # base map
    assert_select "svg.cables-layer polyline" # submarine cable routes
    assert_select "svg.infra circle"         # infrastructure layer
    assert_select "section.panel", minimum: 5
    assert_select ".root-list .spark polyline"           # root latency sparkline
    assert_select "a[href=?]", "https://dnsmon.ripe.net/de"        # degraded TLD deep-link
    assert_select ".tld-list .spark polyline"                      # TLD availability sparkline
    assert_match ".DE {", @response.body                           # degraded ccTLD highlights its country
    assert_select ".root-list a[href=?]", "https://atlas.ripe.net/measurements/10009/"
    assert_select ".outages a[href=?]", "https://ioda.inetintel.cc.gatech.edu/country/BZ"
    assert_match "Internet.RIP", @response.body
    assert_match "GitHub", @response.body
    assert_match "Belize", @response.body
    assert_match ".BZ", @response.body       # outage country highlight style
    assert_select ".anomalies a[href=?]", "https://grip.inetintel.cc.gatech.edu/v1/events/moas/moas-1-1_2"
    assert_match "1.2.3.0/24", @response.body     # ongoing BGP anomaly shows its suspect prefix
    assert_match "resolved", @response.body        # finished BGP anomaly renders without crashing
    assert_select ".resolvers .spark polyline"                      # resolver latency sparkline
    assert_select ".resolvers a[href=?]", "https://1.1.1.1/"
    assert_select "svg.heatmap .heat-down", 2                       # updown.io failing-check heatmap dots
    assert_select ".status-list.updown .spark polyline"             # per-ISP 24h failure-rate sparkline
    assert_match "Failure Rate by ISP", @response.body
    assert_match "9.0% failing", @response.body                     # global failure rate badge
    assert_match "OVH SAS", @response.body

    # Flagged-country tooltip data island (applied client-side to the map's
    # <path> elements; see application.html.erb's poller script).
    assert_select "script#country-issues", 1
    tooltip_data = JSON.parse(css_select("script#country-issues").text)
    assert_equal "Belize", tooltip_data["BZ"]["name"]
    assert_match "outage", tooltip_data["BZ"]["lines"].join
    assert_match "ccTLD degraded", tooltip_data["DE"]["lines"].join
  end

  test "the live endpoint renders just the dynamic layer" do
    get "/live"
    assert_response :success
    assert_select ".status-banner"
    assert_select "section.panel", minimum: 4
    assert_no_match(/<html/, @response.body)
  end

  test "rendered pages are cached briefly, one entry per page" do
    get "/live"
    first = @response.body
    seed OutagesMonitor, { countries: [], count: 0 }

    get "/live"
    assert_equal first, @response.body

    travel 16.seconds
    get "/live"
    assert_not_equal first, @response.body
    assert_equal 1, InternetController::PAGE_CACHE.instance_variable_get(:@data).size
  end

  test "the page still renders on a cold cache without blocking" do
    Rails.cache.clear
    # Hold every monitor's refresh lock so no real network refresh is spawned.
    BaseMonitor.registry.each { |m| Rails.cache.write(m.lock_key, true) }

    get root_path
    assert_response :success
    assert_select ".status-banner.status-unknown" # dot stays dim until every monitor has reported
  end
end
