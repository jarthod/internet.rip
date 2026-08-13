require "cgi"

# Latency + uptime of well-known public recursive DNS resolvers (Google,
# Cloudflare, Quad9, OpenDNS, NextDNS, DNS4EU), sourced from PerfOps/DNSPerf
# (https://www.dnsperf.com/#!dns-resolvers), which tests every provider every
# minute from 200+ locations worldwide and aggregates the result.
#
# This deliberately replaced an earlier version that probed each resolver
# directly from wherever this app runs: a single vantage point produces false
# negatives for resolvers that are regionally blocked or routed differently
# (e.g. OpenDNS is blocked in France) without being down globally. PerfOps'
# many-vantage-point aggregate is the more honest signal for a status page.
#
# Requires a PerfOps API key (Rails.application.credentials.perfops.api_key —
# see `bin/rails credentials:edit`); free-tier accounts are limited to one
# resolver ("source") per request and daily (not hourly/minute) granularity,
# hence the per-resolver fan-out below and the long refresh interval.
class PublicResolversMonitor < BaseMonitor
  self.title = "Public DNS Resolvers"
  self.interval = 3600 # PerfOps' own public data only updates hourly anyway

  API = "https://api.perfops.net/analytics/dns/data".freeze
  WINDOW_DAYS = 30

  # PerfOps resolver ids, from GET https://api.perfops.net/analytics/dns/resolver
  RESOLVERS = {
    "Google"     => { id: 1,  url: "https://developers.google.com/speed/public-dns" },
    "Cloudflare" => { id: 24, url: "https://1.1.1.1/" },
    "Quad9"      => { id: 22, url: "https://www.quad9.net/" },
    "OpenDNS"    => { id: 2,  url: "https://www.opendns.com/" },
    "NextDNS"    => { id: 39, url: "https://nextdns.io/" },
    "DNS4EU"     => { id: 79, url: "https://www.joindns4.eu/" },
  }.freeze

  def fetch
    resolvers = in_parallel(RESOLVERS.to_a) { |name, cfg| build(name, cfg) }.sort_by { _1[:name] }
    { resolvers: resolvers, up: resolvers.count { _1[:status] != "down" }, total: resolvers.size }
  end

  private

  def build(name, cfg)
    json = get_json(request_url(cfg[:id]), timeout: 10, headers: { "Authorization" => api_key })
    series = json["result"] || []
    means = series.find { _1["statFunction"] == "MEAN" }&.dig("data") || []
    uptimes = series.find { _1["statFunction"] == "UPTIME" }&.dig("data") || []

    ms = means.last&.dig("y")&.round(1)
    uptime = uptimes.last && (uptimes.last["y"] * 100).round(2)

    { name: name, url: cfg[:url], ms: ms, uptime: uptime, status: status_for(uptime),
      spark: means.filter_map { _1["y"] } }
  rescue => e
    { name: name, url: cfg[:url], ms: nil, uptime: nil, status: "unknown", spark: [], error: e.class.name.demodulize }
  end

  # Real-world 30d uptime for these providers commonly sits in the
  # high-98%/99% range (per-vantage-point blips count against it even when
  # the resolver is fine globally), so >=98% reads as ok rather than amber.
  def status_for(uptime)
    return "unknown" unless uptime

    uptime >= 98.0 ? "ok" : (uptime >= 95.0 ? "warn" : "down")
  end

  def request_url(resolver_id)
    now = Time.now.utc
    params = {
      dateTimeFrom: (now - WINDOW_DAYS.days).strftime("%Y-%m-%d %H:%M:%S"),
      dateTimeTo: now.strftime("%Y-%m-%d %H:%M:%S"),
      groupByTime: "day", # free-tier cap: hour/minute grouping is paid-only
      statFunction: "mean,uptime",
      type: "resolver",
      providers: resolver_id, # free-tier cap: exactly one source per request
    }
    "#{API}?#{params.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')}"
  end

  def api_key
    Rails.application.credentials.dig(:perfops, :api_key)
  end
end
