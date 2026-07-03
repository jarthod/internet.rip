# Refreshes the static map datasets from their upstream sources.
#
#   rake data:update          # everything below
#   rake data:cables          # submarine cable routes      (TeleGeography)
#   rake data:landing_points  # submarine cable landings     (TeleGeography)
#   rake data:ixps            # internet exchange points     (PeeringDB)
#
# These are plain HTTP downloads with no app dependencies, so the task is quick
# and safe to run from cron.
require "net/http"
require "json"
require "fileutils"

namespace :data do
  ROOT = File.expand_path("../..", __dir__)

  CABLE_GEO   = "https://www.submarinecablemap.com/api/v3/cable/cable-geo.json".freeze
  LANDING_GEO = "https://www.submarinecablemap.com/api/v3/landing-point/landing-point-geo.json".freeze
  PDB         = "https://www.peeringdb.com/api".freeze

  desc "Refresh every map dataset"
  task update: %i[cables landing_points ixps] do
    puts "\nAll map data updated."
  end

  desc "Submarine cable routes (TeleGeography Submarine Cable Map)"
  task :cables do
    save "data/submarinecables/cable-geo.json", http_get(CABLE_GEO)
  end

  desc "Submarine cable landing points (TeleGeography Submarine Cable Map)"
  task :landing_points do
    save "data/submarinecables/landing-point-geo.json", http_get(LANDING_GEO)
  end

  desc "Internet Exchange Points, geocoded via PeeringDB facilities"
  task :ixps do
    ixps = json("#{PDB}/ix?fields=id,name,city,country")["data"]
    facs = json("#{PDB}/fac?fields=id,latitude,longitude")["data"]
      .to_h { |f| [f["id"], f] }
    links = json("#{PDB}/ixfac?fields=ix_id,fac_id")["data"]

    # An IXP sits at one or more facilities; use its first geocoded facility.
    coords = {}
    links.each do |l|
      f = facs[l["fac_id"]]
      next unless f && f["latitude"] && f["longitude"] && f["latitude"] != 0

      coords[l["ix_id"]] ||= [f["longitude"], f["latitude"]]
    end

    features = ixps.filter_map do |ix|
      point = coords[ix["id"]]
      next unless point

      { type: "Feature", geometry: { type: "Point", coordinates: point },
        properties: { name: ix["name"], city: ix["city"], country: ix["country"] } }
    end

    save "data/peeringdb/ixps.json", JSON.generate(type: "FeatureCollection", features: features)
    puts "  geocoded #{features.size} of #{ixps.size} IXPs"
  end

  # --- helpers --------------------------------------------------------------

  def http_get(url)
    uri = URI(url)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
      http.get(uri.request_uri, "User-Agent" => "internet.rip data updater")
    end
    raise "GET #{url} failed: #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    res.body
  end

  def json(url) = JSON.parse(http_get(url))

  def save(relative, body)
    path = File.join(ROOT, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, body)
    puts "  wrote #{relative} (#{body.bytesize / 1024} kB)"
  end
end
