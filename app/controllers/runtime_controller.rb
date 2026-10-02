class RuntimeController < ApplicationController
  before_action :require_runtime_dashboard

  def show
  end

  def stats
    response.headers["Cache-Control"] = "no-store"
    path = ENV.fetch("RUNTIME_STATS_PATH") { Rails.root.join("storage/runtime_stats.json").to_s }
    render plain: File.read(path), content_type: "application/json"
  rescue StandardError
    render plain: '{"available":false,"error":"Runtime collector is waiting for its first sample"}', content_type: "application/json", status: :service_unavailable
  end

  private
    def require_runtime_dashboard
      head :not_found unless ENV["RUNTIME_DASHBOARD_ENABLED"] == "true"
    end
end
