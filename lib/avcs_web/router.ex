defmodule AvcsWeb.Router do
  use AvcsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AvcsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AvcsWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/web", WebController, :index
    get "/web/*path", WebController, :index
  end

  scope "/api", AvcsWeb do
    pipe_through :api

    get "/health", HealthController, :show

    post "/project/create_blank", ProjectController, :create_blank
    post "/project/open", ProjectController, :open
    get "/project/sqlite_info", ProjectController, :sqlite_info
    post "/project/sqlite_maintenance", ProjectController, :sqlite_maintenance

    get "/assets/:id/preview", AssetController, :preview
    post "/assets/import", AssetController, :import
    post "/assets/upload", AssetController, :upload
    post "/assets/upload_to_output", AssetController, :upload_to_output
    post "/assets/mask", AssetController, :mask
    post "/assets/scan", AssetController, :scan
    post "/assets/:id/copy_to_output", AssetController, :copy_to_output
    post "/assets/:id/reveal", AssetController, :reveal
    get "/assets/:id/path", AssetController, :path
    delete "/assets/:id", AssetController, :delete
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:avcs, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AvcsWeb.Telemetry
    end
  end
end
