defmodule AvcsWeb.Plugs.ViteProxy do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    prefix = Keyword.fetch!(opts, :path_prefix)
    path = if conn.request_path == prefix, do: prefix <> "/", else: conn.request_path

    if conn.method in ["GET", "HEAD"] and String.starts_with?(path, prefix) do
      proxy(conn, opts, path)
    else
      conn
    end
  end

  defp proxy(conn, opts, path) do
    port = Keyword.fetch!(opts, :port)
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    url = String.to_charlist("http://127.0.0.1:#{port}#{path}#{query}")

    request = {url, request_headers(conn)}
    http_opts = [timeout: 5_000]
    opts = [body_format: :binary]

    case :httpc.request(method(conn.method), request, http_opts, opts) do
      {:ok, {{_version, status, _reason}, headers, body}} ->
        conn =
          headers
          |> Enum.reduce(conn, fn {key, value}, acc ->
            key = key |> to_string() |> String.downcase()

            if key in ["content-type", "cache-control"] do
              put_resp_header(acc, key, to_string(value))
            else
              acc
            end
          end)

        conn
        |> send_resp(status, body)
        |> halt()

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(502, "Vite dev server is not reachable on port #{port}: #{inspect(reason)}")
        |> halt()
    end
  end

  defp request_headers(conn) do
    conn.req_headers
    |> Enum.reject(fn {key, _value} -> key in ["host", "content-length"] end)
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp method("GET"), do: :get
  defp method("HEAD"), do: :head
end
