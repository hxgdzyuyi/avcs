defmodule Avcs.Agent.DataProviderScriptTest do
  use ExUnit.Case, async: true

  test "APOD downloader retries incomplete reads before writing image" do
    python = System.find_executable("python3") || System.find_executable("python")
    assert python

    script = Path.expand("priv/skills/avcs-data-prodiver-apod/scripts/fetch_apod.py")

    code = """
    import importlib.util
    import pathlib
    import sys
    import tempfile
    from http.client import IncompleteRead

    sys.dont_write_bytecode = True

    spec = importlib.util.spec_from_file_location("fetch_apod", #{Jason.encode!(script)})
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    calls = {"count": 0}

    class FakeResponse:
        headers = {"Content-Type": "image/jpeg"}

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def read(self):
            calls["count"] += 1
            if calls["count"] == 1:
                raise IncompleteRead(b"partial", 7)
            return b"complete-image"

    def fake_urlopen(req, timeout=30):
        return FakeResponse()

    module.urlopen = fake_urlopen
    out = pathlib.Path(tempfile.mkdtemp()) / "image.jpg"

    module._download_image("https://example.test/image.jpg", out)

    assert out.read_bytes() == b"complete-image"
    assert calls["count"] == 2
    """

    {output, status} = System.cmd(python, ["-c", code], stderr_to_stdout: true)
    assert status == 0, output
  end

  test "APOD candidate URLs prefer HD and do not reuse web page URL as an image" do
    python = System.find_executable("python3") || System.find_executable("python")
    assert python

    script = Path.expand("priv/skills/avcs-data-prodiver-apod/scripts/fetch_apod.py")

    code = """
    import importlib.util
    import sys

    sys.dont_write_bytecode = True

    spec = importlib.util.spec_from_file_location("fetch_apod", #{Jason.encode!(script)})
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    payload = {
        "url": "https://apod.nasa.gov/apod/image.jpg",
        "hdurl": "https://apod.nasa.gov/apod/image-hd.jpg",
    }

    assert module._image_url_candidates(
        payload,
        "https://apod.nasa.gov/apod/image.jpg",
        True,
        "api",
    ) == [
        "https://apod.nasa.gov/apod/image-hd.jpg",
        "https://apod.nasa.gov/apod/image.jpg",
    ]

    assert module._image_url_candidates(
        {"url": "https://apod.nasa.gov/apod/ap260609.html"},
        "https://apod.nasa.gov/apod/image.jpg",
        True,
        "web_scrape",
    ) == ["https://apod.nasa.gov/apod/image.jpg"]
    """

    {output, status} = System.cmd(python, ["-c", code], stderr_to_stdout: true)
    assert status == 0, output
  end
end
