defmodule AtlasWeb.Router do
  use AtlasWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AtlasWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AtlasWeb do
    pipe_through :browser

    live_session :default do
      live "/", FileBrowserLive, :index
      live "/l/:location_id", FileBrowserLive, :show
      live "/l/:location_id/f/:file_id", FileBrowserLive, :file_detail
      live "/l/:location_id/settings", FileBrowserLive, :location_settings
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:atlas_web, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AtlasWeb.Telemetry
    end
  end
end
