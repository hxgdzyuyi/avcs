defmodule AvcsWeb.WebController do
  use AvcsWeb, :controller

  def index(conn, _params) do
    index_path = Path.join(:code.priv_dir(:avcs), "static/assets/web/index.html")

    if File.exists?(index_path) do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, index_path)
    else
      html(conn, """
      <!doctype html>
      <html>
        <head><meta charset="utf-8"><title>Avcs</title></head>
        <body style="font: 14px system-ui; padding: 24px;">
          <h1>Avcs web build is missing</h1>
          <p>In development, start Vite with <code>cd web && npm run dev -- --host 127.0.0.1 --port 9501</code>.</p>
          <p>For production-style serving, run <code>cd web && npm run build</code>.</p>
        </body>
      </html>
      """)
    end
  end
end
