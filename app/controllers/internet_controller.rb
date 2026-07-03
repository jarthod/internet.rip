class InternetController < ApplicationController
  before_action :load_monitors

  # Full dashboard: heavy static base map + the live overlay/panels.
  def index
  end

  # Just the dynamic layer, polled by the browser every few seconds so the big
  # base map doesn't have to be re-rendered.
  def live
    render partial: "live", layout: false
  end

  private

  def load_monitors
    # Read snapshots first: referencing each constant ensures it is autoloaded
    # and registered before we ask the registry to refresh stale ones.
    @root     = RootServersMonitor.snapshot
    @tlds     = TldMonitor.snapshot
    @services = ServiceStatusMonitor.snapshot
    @sites    = PublicSitesMonitor.snapshot
    @outages  = OutagesMonitor.snapshot

    BaseMonitor.refresh_all_if_stale # non-blocking; page renders from cache
  end
end
