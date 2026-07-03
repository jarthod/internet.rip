# Static internet-infrastructure geography, loaded once and memoized. All the
# source files are GeoJSON with [lng, lat] coordinates; we return [lat, lng].
# Refresh the underlying files with `rake data:update` (see lib/tasks/data.rake).
module Infrastructure
  DATA_DIR = Rails.root.join("data")

  module_function

  # Internet Exchange Points — the interconnection hubs of the internet (PeeringDB).
  def ixps = @ixps ||= points("peeringdb/ixps.json")

  # Submarine cable landing points — where undersea cables meet land (TeleGeography).
  def landing_stations = @landing_stations ||= points("submarinecables/landing-point-geo.json")

  # Submarine cable routes from TeleGeography's open Submarine Cable Map.
  # Each cable is a MultiLineString; we return [name, segments] where a segment
  # is an array of [lat, lng] points. (No live status is published for these.)
  def submarine_cables = @submarine_cables ||= load_cables

  def load_cables
    JSON.parse(File.read(DATA_DIR.join("submarinecables/cable-geo.json")))["features"].map do |f|
      segments = f.dig("geometry", "coordinates").map do |line|
        line.map { |lng, lat| [lat, lng] }
      end
      { name: f.dig("properties", "name"), segments: segments }
    end
  rescue Errno::ENOENT
    []
  end

  def points(file)
    features = JSON.parse(File.read(DATA_DIR.join(file)))["features"]
    features.filter_map do |f|
      lng, lat = f.dig("geometry", "coordinates")
      next unless lat && lng

      { lat: lat, lng: lng, name: f.dig("properties", "name") }
    end
  rescue Errno::ENOENT
    []
  end
end
