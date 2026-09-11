# Availability & latency of the 13 DNS root servers (A-M), taken straight from
# RIPE's DNSMON rather than reproducing its aggregation ourselves.
#
# DNSMON's own API returns, per root server, a time series of 10-minute buckets
# with query/reply counts (→ availability) and RTT percentiles (rtt50 = median
# latency), already aggregated across its global probe fleet. We surface the most
# recent bucket for the current reading and the rtt50 series as a sparkline.
# Because every point comes from the same aggregation, the sparkline is smooth.
class RootServersMonitor < BaseMonitor
  self.title = "DNS Root Servers"
  self.interval = 300

  API = "https://dnsmon.ripe.net/api/servers?group=root".freeze
  SPARK_POINTS = 48 # downsample the ~24h series to keep the sparkline crisp
  UP_THRESHOLD = 75 # % of queries answered for a "green" root (down only below ~25% failure)

  def fetch
    json = get_json(API, timeout: 12)
    servers = Array(json["servers"])
      .select { _1["ip_version"] == 4 } # one row per letter (A-M)
      .map { build(_1) }
      .sort_by { _1[:letter] }

    { servers: servers, up: servers.count { _1[:up] }, total: servers.size }
  end

  private

  def build(server)
    results = Array(server["results"])
    latest = results.reverse.find { _1["queries"].to_i.positive? }
    avail = latest && (100.0 * latest["replies"] / latest["queries"])
    median = latest && latest["rtt50"]&.round(1)
    spark = downsample(results.filter_map { _1["rtt50"] }, SPARK_POINTS)

    {
      letter: server["hostname"][0],
      avail: avail,
      median: median,
      up: avail ? avail >= UP_THRESHOLD : false,
      spark: spark,
      url: server.dig("atlas_measurements", 0, "overview_url") || "https://dnsmon.ripe.net/",
    }
  end
end
