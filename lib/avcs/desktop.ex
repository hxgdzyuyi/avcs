defmodule Avcs.Desktop do
  @moduledoc false

  require Logger

  def default_url do
    web_url("/web/")
  end

  def expand_desktop_url(nil), do: default_url()
  def expand_desktop_url(""), do: default_url()
  def expand_desktop_url("/"), do: default_url()
  def expand_desktop_url("/settings"), do: web_url("/web/settings")

  def expand_desktop_url("file://" <> _ = url) do
    url
    |> file_url_path()
    |> project_url()
  end

  def expand_desktop_url("avcs://" <> _ = url) do
    expand_deep_link(url)
  end

  def expand_desktop_url("http://" <> _ = url), do: url
  def expand_desktop_url("https://" <> _ = url), do: url

  def expand_desktop_url("/" <> _ = path) do
    web_url(path)
  end

  def expand_desktop_url(_other), do: default_url()

  def browser_open(url) do
    win_cmd_args = ["/c", "start", String.replace(url, "&", "^&")]

    command =
      case :os.type() do
        {:win32, _} ->
          {"cmd", win_cmd_args}

        {:unix, :darwin} ->
          {"open", [url]}

        {:unix, _} ->
          cond do
            exe = System.find_executable("xdg-open") ->
              {exe, [url]}

            System.find_executable("cmd.exe") ->
              {"cmd.exe", win_cmd_args}

            true ->
              nil
          end
      end

    case command do
      {cmd, args} -> System.cmd(cmd, args)
      nil -> Logger.warning("could not open browser URL #{inspect(url)}")
    end

    :ok
  end

  def open_file(path) do
    command =
      case :os.type() do
        {:win32, _} ->
          {"cmd.exe", ["/c", "start", "", path]}

        {:unix, :darwin} ->
          {"open", [path]}

        {:unix, _} ->
          if exe = System.find_executable("xdg-open"), do: {exe, [path]}, else: nil
      end

    case command do
      {cmd, args} -> System.cmd(cmd, args)
      nil -> Logger.warning("could not open file #{inspect(path)}")
    end

    :ok
  end

  defp expand_deep_link(url) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    path_command = uri.path |> to_string() |> String.trim_leading("/")
    command = uri.host || path_command

    cond do
      command == "settings" ->
        web_url("/web/settings")

      command in ["open", "project"] and is_binary(query["path"]) ->
        project_url(query["path"])

      true ->
        default_url()
    end
  end

  defp web_url(path, query \\ nil) do
    endpoint_url = AvcsWeb.Endpoint.config(:url) || []
    http = AvcsWeb.Endpoint.config(:http) || []

    host =
      if System.get_env("AVCS_DESKTOP") == "true" do
        "127.0.0.1"
      else
        Keyword.get(endpoint_url, :host, "localhost")
      end

    port =
      System.get_env("PORT") ||
        Keyword.get(endpoint_url, :port) ||
        Keyword.get(http, :port)

    %URI{
      scheme: to_string(Keyword.get(endpoint_url, :scheme, "http")),
      host: host,
      port: normalize_port(port),
      path: path,
      query: query
    }
    |> URI.to_string()
  end

  defp project_url(path) do
    project_path =
      path
      |> URI.decode()
      |> Path.expand()
      |> project_folder_path()

    web_url("/web/", URI.encode_query(%{"project_path" => project_path}))
  end

  defp project_folder_path(path) do
    cond do
      File.dir?(path) -> path
      Path.extname(path) == ".avcs" -> Path.dirname(path)
      true -> path
    end
  end

  defp file_url_path(url) do
    url
    |> URI.parse()
    |> Map.get(:path, "")
  end

  defp normalize_port(nil), do: nil
  defp normalize_port(port) when is_integer(port), do: port

  defp normalize_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {value, ""} -> value
      _ -> nil
    end
  end
end
