# Checks reachability and latency of a handful of landmark sites. These are the
# "can I reach the internet at all" canaries.
class PublicSitesMonitor < BaseMonitor
  self.title = "Public Sites"
  self.interval = 60

  SITES = {
    "Google"     => "https://www.google.com",
    "Cloudflare" => "https://www.cloudflare.com",
    "GitHub"     => "https://github.com",
    "Wikipedia"  => "https://www.wikipedia.org",
    "Amazon"     => "https://www.amazon.com",
    "Microsoft"  => "https://www.microsoft.com",
    "YouTube"    => "https://www.youtube.com",
    "X"          => "https://x.com",
  }.freeze

  def fetch
    sites = in_parallel(SITES.to_a) do |name, url|
      result = probe(url)
      { name: name, url: url, up: result[:up], code: result[:code],
        ms: result[:ms], error: result[:error] }
    end.sort_by { |s| s[:name] }
    { sites: sites, up: sites.count { _1[:up] }, total: sites.size }
  end
end
