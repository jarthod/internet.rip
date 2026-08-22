# Global heatmap of currently-failing checks from updown.io (the maintainer's
# own uptime-monitoring service), plus the ISPs with the worst 24h failure
# rate. Both are pre-aggregated server-side by updown's InternetRipController
# — geo rounded to whole degrees, checks down for over a week excluded as
# chronic/abandoned rather than a real-time outage, ISPs below a minimum
# sample size dropped — so no individual customer's check is ever exposed
# here. The upstream feed doesn't distinguish down vs. degraded, so this is
# just "currently failing".
#
# Deliberately excluded from the overall status banner: some fraction of a
# large, unrelated customer base is always down for reasons that have nothing
# to do with broader internet health (their own server crashed, a forgotten
# check nobody deleted, ...), so this is a feed to look at, not a health
# signal — same reasoning as GripMonitor.
class UpdownMonitor < BaseMonitor
  self.title = "Failed Checks by AS"
  self.interval = 120 # a bit longer than updown's own 60s upstream cache

  API = "https://updown.io/internet-rip/overview".freeze

  def fetch
    json = get_json(API, timeout: 10, headers: { "X-Internet-Rip-Token" => api_token })

    points = Array(json["points"]).filter_map { |p| build_point(p) }
    top_isps = Array(json["top_isps"]).map { |i| build_isp(i) }
    total = json["total"].to_i
    failing = json["failing"].to_i

    { points: points, top_isps: top_isps, total: total, failing: failing,
      rate: total > 0 ? failing.to_f / total : nil }
  end

  private

  def build_point(p)
    return nil unless p["lat"] && p["lng"]

    { lat: p["lat"].to_f, lng: p["lng"].to_f, count: p["count"].to_i }
  end

  def build_isp(i)
    { name: i["isp"], down: i["down"].to_i, total: i["total"].to_i, rate: i["rate"].to_f, spark: i["spark"] }
  end

  def api_token
    Rails.application.credentials.dig(:updown, :token)
  end
end
