defmodule Avcs.DesktopTest do
  use ExUnit.Case, async: true

  setup do
    previous_desktop = System.get_env("AVCS_DESKTOP")
    previous_port = System.get_env("PORT")

    System.put_env("AVCS_DESKTOP", "true")
    System.put_env("PORT", "49152")

    on_exit(fn ->
      restore_env("AVCS_DESKTOP", previous_desktop)
      restore_env("PORT", previous_port)
    end)
  end

  test "default URL points at the browser app entry" do
    assert Avcs.Desktop.default_url() == "http://127.0.0.1:49152/web/"
  end

  test "settings deep link opens the settings route" do
    assert Avcs.Desktop.expand_desktop_url("avcs://settings") ==
             "http://127.0.0.1:49152/web/settings"
  end

  test "open deep link passes the project path through the web query" do
    url = Avcs.Desktop.expand_desktop_url("avcs://open?path=/Users/qingyang/Project")
    uri = URI.parse(url)

    assert uri.path == "/web/"
    assert URI.decode_query(uri.query)["project_path"] == "/Users/qingyang/Project"
  end

  test "avcs file association uses the containing folder as project path" do
    url = Avcs.Desktop.expand_desktop_url("file:///Users/qingyang/Project.avcs")
    uri = URI.parse(url)

    assert uri.path == "/web/"
    assert URI.decode_query(uri.query)["project_path"] == "/Users/qingyang"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
