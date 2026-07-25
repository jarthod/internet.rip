require "nokogiri"

# Aggregates the public status pages of major hosting/CDN/DNS infrastructure
# providers. Most large providers run Atlassian Statuspage, which exposes a
# machine-readable `/api/v2/incidents/unresolved.json`. We read unresolved
# incidents rather than `/api/v2/status.json`'s aggregate indicator: providers
# like Cloudflare track hundreds of granular network-location components, and
# routine per-PoP maintenance/partial-outage flags there drag the aggregate
# indicator to "minor" even with zero actual incidents — noise the provider's
# own status page doesn't surface as a headline issue either. AWS, GCP, and
# Azure don't publish a Statuspage-compatible API, so they're each fetched
# from their own feed and parsed into the same shape.
class ServiceStatusMonitor < BaseMonitor
  self.title = "Major Hosting Services"
  self.interval = 120

  # name => statuspage base URL
  STATUSPAGE_SERVICES = {
    "Cloudflare"   => "https://www.cloudflarestatus.com",
    "DigitalOcean" => "https://status.digitalocean.com",
    "Akamai"       => "https://www.akamaistatus.com",
    "Vercel"       => "https://www.vercel-status.com",
    "Netlify"      => "https://www.netlifystatus.com",
    "Linode"       => "https://status.linode.com",
  }.freeze

  AWS_RSS   = "https://status.aws.amazon.com/rss/all.rss".freeze
  GCP_JSON  = "https://status.cloud.google.com/incidents.json".freeze
  AZURE_RSS = "https://azure.status.microsoft/status/feed/".freeze

  GCP_INDICATOR = { "high" => "major", "medium" => "minor", "low" => "minor" }.freeze
  IMPACT_RANK = { "none" => 0, "minor" => 1, "major" => 2, "critical" => 3 }.freeze

  # Worst first.
  SEVERITY = %w[critical major minor none unknown].freeze

  def fetch
    statuspage = in_parallel(STATUSPAGE_SERVICES.to_a) { |name, base| fetch_statuspage(name, base) }
    bespoke = in_parallel(%i[aws gcp azure]) { |provider| send("fetch_#{provider}") }
    (statuspage + bespoke).sort_by { |s| [SEVERITY.index(s[:indicator]) || 99, s[:name]] }
  end

  private

  def fetch_statuspage(name, base)
    incidents = get_json("#{base}/api/v2/incidents/unresolved.json", timeout: 6)["incidents"]
    worst = Array(incidents).max_by { |i| IMPACT_RANK[i["impact"]] || -1 }
    { name: name, url: base, indicator: worst ? worst["impact"] : "none",
      description: worst&.dig("name"), error: nil }
  rescue => e
    { name: name, url: base, indicator: "unknown", description: nil, error: e.class.name.demodulize }
  end

  # AWS has no public JSON status API; infer from the most recent RSS item.
  # Titles look like "Service is operating normally: [RESOLVED] Connectivity
  # Issues" when resolved, or an active title without that marker otherwise.
  # Heuristic, not authoritative.
  def fetch_aws
    doc = Nokogiri::XML(http_get(AWS_RSS, timeout: 8).body)
    item = doc.at_xpath("//item")
    title = item&.at_xpath("title")&.text
    pub = item&.at_xpath("pubDate")&.text
    recent = pub && (Time.parse(pub) > 6.hours.ago rescue false)
    active = recent && title && !(title.start_with?("Service is operating normally") || title.include?("[RESOLVED]"))
    { name: "AWS", url: "https://status.aws.amazon.com/", error: nil,
      indicator: active ? "minor" : "none", description: active ? title : nil }
  rescue => e
    { name: "AWS", url: "https://status.aws.amazon.com/", indicator: "unknown", description: nil, error: e.class.name.demodulize }
  end

  def fetch_gcp
    active = Array(get_json(GCP_JSON, timeout: 8)).select { |i| i["end"].nil? }
    worst = active.max_by { |i| %w[low medium high].index(i["severity"]) || -1 }
    { name: "GCP", url: "https://status.cloud.google.com/", error: nil,
      indicator: worst ? (GCP_INDICATOR[worst["severity"]] || "minor") : "none",
      description: worst&.dig("external_desc") }
  rescue => e
    { name: "GCP", url: "https://status.cloud.google.com/", indicator: "unknown", description: nil, error: e.class.name.demodulize }
  end

  # Lower confidence than AWS/GCP: the shape of an active <item> wasn't
  # directly observed (feed had none at implementation time) — parse
  # defensively. Presence of any item is treated as an active issue.
  def fetch_azure
    doc = Nokogiri::XML(http_get(AZURE_RSS, timeout: 8).body)
    item = doc.at_xpath("//item")
    { name: "Azure", url: "https://azure.status.microsoft/en-us/status/", error: nil,
      indicator: item ? "minor" : "none", description: item&.at_xpath("title")&.text&.strip }
  rescue => e
    { name: "Azure", url: "https://azure.status.microsoft/en-us/status/", indicator: "unknown", description: nil, error: e.class.name.demodulize }
  end
end
