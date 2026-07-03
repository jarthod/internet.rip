# Aggregates the public status pages of major internet services. Most large
# providers run Atlassian Statuspage, which exposes a machine-readable
# `/api/v2/status.json` with a normalized indicator (none/minor/major/critical).
class ServiceStatusMonitor < BaseMonitor
  self.title = "Service Status"
  self.interval = 120

  # name => statuspage base URL
  SERVICES = {
    "GitHub"        => "https://www.githubstatus.com",
    "Cloudflare"    => "https://www.cloudflarestatus.com",
    "Discord"       => "https://discordstatus.com",
    "Reddit"        => "https://www.redditstatus.com",
    "DigitalOcean"  => "https://status.digitalocean.com",
    "npm"           => "https://status.npmjs.org",
    "Twilio"        => "https://status.twilio.com",
    "Datadog"       => "https://status.datadoghq.com",
    "Coinbase"      => "https://status.coinbase.com",
    "SendGrid"      => "https://status.sendgrid.com",
  }.freeze

  def fetch
    in_parallel(SERVICES.to_a) do |name, base|
      begin
        json = get_json("#{base}/api/v2/status.json", timeout: 6)
        status = json.dig("status", "indicator") || "unknown"
        { name: name, url: base, indicator: status,
          description: json.dig("status", "description"), error: nil }
      rescue => e
        { name: name, url: base, indicator: "unknown",
          description: nil, error: e.class.name.demodulize }
      end
    end.sort_by { |s| [SEVERITY.index(s[:indicator]) || 99, s[:name]] }
  end

  # Worst first.
  SEVERITY = %w[critical major minor none unknown].freeze
end
