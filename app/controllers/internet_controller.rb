class InternetController < ApplicationController
  # In-process rather than Rails.cache (a file store in production) to avoid many disk writes
  PAGE_CACHE = ActiveSupport::Cache::MemoryStore.new(size: 4.megabytes)

  before_action :load_monitors

  # Full dashboard: heavy static base map + the live overlay/panels.
  def index
    render html: cached_page("index") { render_to_string }
  end

  # Just the dynamic layer, polled by the browser every few seconds so the big
  # base map doesn't have to be re-rendered.
  def live
    render html: cached_page("live") { render_to_string(partial: "live", layout: false) }
  end

  private

  def cached_page(key, &block)
    PAGE_CACHE.fetch(key, expires_in: 10.seconds, race_condition_ttl: 5.seconds, &block).html_safe
  end

  def load_monitors
    # Read snapshots first: referencing each constant ensures it is autoloaded
    # and registered before we ask the registry to refresh stale ones.
    @root      = RootServersMonitor.snapshot
    @tlds      = TldMonitor.snapshot
    @services  = ServiceStatusMonitor.snapshot
    @sites     = PublicSitesMonitor.snapshot
    @outages   = OutagesMonitor.snapshot
    @grip      = GripMonitor.snapshot
    @resolvers = PublicResolversMonitor.snapshot
    @updown    = UpdownMonitor.snapshot

    BaseMonitor.refresh_all_if_stale # non-blocking; page renders from cache
  end
end
