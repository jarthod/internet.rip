require "net/http"
require "json"
require "resolv"

# Base class for all data collectors.
#
# A monitor knows how to `fetch` a fresh snapshot from some external source. The
# result is cached in-process with a TTL and refreshed in a background thread, so
# rendering the dashboard never blocks on the network (stale-while-revalidate).
#
# Subclasses implement `#fetch` (returning any serializable data) and may set a
# `self.interval` (seconds before a snapshot is considered stale).
#
# NOTE: named BaseMonitor rather than Monitor because Ruby's stdlib already
# defines a top-level ::Monitor (the thread mutex), which would shadow us.
class BaseMonitor
  # A frozen view of a monitor's last result handed to the views.
  Snapshot = Struct.new(:data, :updated_at, :error, keyword_init: true) do
    def ok? = error.nil?
    def loading? = updated_at.nil?
    def stale?(interval) = updated_at.nil? || updated_at < interval.seconds.ago
    def age = updated_at && (Time.current - updated_at).round
  end

  # Per-monitor configuration, set in each subclass. `interval` is the number of
  # seconds before a cached snapshot is considered stale.
  class << self
    attr_writer :title, :interval
    def title = @title || "Monitor"
    def interval = @interval || 60
  end

  # --- Registry -------------------------------------------------------------

  def self.registry = @registry ||= []

  def self.inherited(subclass)
    super
    BaseMonitor.registry << subclass
  end

  # Kick a background refresh for every monitor whose snapshot is stale. Returns
  # immediately; the dashboard renders from whatever is already cached.
  def self.refresh_all_if_stale
    registry.each(&:refresh_if_stale)
  end

  # --- Per-monitor cache ----------------------------------------------------

  def self.cache_key = "monitor:#{name}"
  def self.lock_key  = "monitor-lock:#{name}"

  def self.snapshot
    stored = Rails.cache.read(cache_key)
    return Snapshot.new(data: nil, updated_at: nil, error: nil) unless stored

    Snapshot.new(**stored)
  end

  # Non-blocking: spawn a background thread to refresh when stale, but only if no
  # other refresh for this monitor is already in flight (short-lived cache lock).
  def self.refresh_if_stale
    return unless snapshot.stale?(interval)
    return unless Rails.cache.write(lock_key, true, unless_exist: true, expires_in: 2.minutes)

    Thread.new do
      Rails.application.executor.wrap { refresh! }
    ensure
      Rails.cache.delete(lock_key)
    end
  end

  # Blocking refresh (used by the background thread and the warm-up rake task).
  def self.refresh!
    data = new.fetch
    Rails.cache.write(cache_key, { data: data, updated_at: Time.current, error: nil })
  rescue => e
    Rails.logger.warn("[#{name}] refresh failed: #{e.class}: #{e.message}")
    previous = Rails.cache.read(cache_key)
    Rails.cache.write(cache_key, {
      data: previous&.dig(:data),
      updated_at: previous&.dig(:updated_at),
      error: "#{e.class}: #{e.message}"
    })
  end

  # --- HTTP / DNS helpers for subclasses ------------------------------------

  # GET a URL and parse the JSON body. Raises on failure (caught by refresh!).
  def get_json(url, timeout: 6)
    JSON.parse(http_get(url, timeout: timeout).body)
  end

  def http_get(url, timeout: 6)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                    open_timeout: timeout, read_timeout: timeout) do |http|
      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = "internet.rip status monitor (+https://internet.rip)"
      http.request(req)
    end
  end

  # Reachability + latency probe. Returns { up:, code:, ms:, error: }.
  def probe(url, method: Net::HTTP::Head, timeout: 5)
    uri = URI(url)
    started = monotonic
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                               open_timeout: timeout, read_timeout: timeout) do |http|
      req = method.new(uri)
      req["User-Agent"] = "internet.rip status monitor (+https://internet.rip)"
      http.request(req)
    end
    code = response.code.to_i
    { up: code < 500, code: code, ms: elapsed_ms(started), error: nil }
  rescue => e
    { up: false, code: nil, ms: elapsed_ms(started), error: e.class.name.demodulize }
  end

  # Query a specific DNS server for a record. Returns { up:, ms:, error: }.
  def dns_probe(server_ip, name: ".", type: Resolv::DNS::Resource::IN::SOA, timeout: 4)
    started = monotonic
    Resolv::DNS.open(nameserver: [server_ip]) do |dns|
      dns.timeouts = timeout
      dns.getresource(name.empty? ? "." : name, type)
    end
    { up: true, ms: elapsed_ms(started), error: nil }
  rescue => e
    { up: false, ms: elapsed_ms(started), error: e.class.name.demodulize }
  end

  # Run a list of items through a block concurrently (bounded by the block's own
  # timeouts) and collect the results in order.
  def in_parallel(items, &block)
    items.map { |item| Thread.new { block.call(item) } }.map(&:value)
  end

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def elapsed_ms(started) = ((monotonic - started) * 1000).round
end
