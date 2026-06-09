defmodule Avcs.HTTPTestServer do
  @moduledoc false

  def start!(steps, opts \\ []) do
    parent = Keyword.get(opts, :parent, self())
    port = Keyword.get(opts, :port, 0)
    delay_ms = Keyword.get(opts, :delay_ms, 0)

    if delay_ms > 0 do
      task =
        Task.async(fn ->
          Process.sleep(delay_ms)
          {:ok, listen_socket} = listen(port)

          try do
            accept_steps(listen_socket, parent, steps)
          after
            :gen_tcp.close(listen_socket)
          end
        end)

      %{port: port, task: task, listen_socket: nil}
    else
      {:ok, listen_socket} = listen(port)
      {:ok, actual_port} = :inet.port(listen_socket)

      task =
        Task.async(fn ->
          try do
            accept_steps(listen_socket, parent, steps)
          after
            :gen_tcp.close(listen_socket)
          end
        end)

      %{port: actual_port, task: task, listen_socket: listen_socket}
    end
  end

  def stop(%{task: task, listen_socket: listen_socket}) do
    if listen_socket, do: :gen_tcp.close(listen_socket)

    case Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, _result} -> :ok
      _result -> :ok
    end
  end

  def reserve_port do
    {:ok, socket} = listen(0)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  def sse_chunk(chunk), do: "data: #{Jason.encode!(chunk)}\n\n"
  def sse_done, do: "data: [DONE]\n\n"

  defp listen(port) do
    :gen_tcp.listen(port, [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1}
    ])
  end

  defp accept_steps(_listen_socket, _parent, []), do: :ok

  defp accept_steps(listen_socket, parent, [step | rest]) do
    with {:ok, socket} <- :gen_tcp.accept(listen_socket),
         {:ok, raw_request} <- read_http_request(socket, "") do
      send(parent, {:http_request, parse_http_request(raw_request)})

      handler =
        Task.async(fn ->
          try do
            run_step(socket, step)
          after
            :gen_tcp.close(socket)
          end
        end)

      accept_steps(listen_socket, parent, rest)
      Task.await(handler, 5_000)
      :ok
    else
      {:error, _reason} -> :ok
    end
  end

  defp run_step(_socket, :close), do: :ok

  defp run_step(socket, {:sleep, milliseconds}) do
    Process.sleep(milliseconds)
    :gen_tcp.close(socket)
  end

  defp run_step(socket, {:json, body, opts}) do
    send_response(
      socket,
      Keyword.get(opts, :status, 200),
      Keyword.get(opts, :reason, "OK"),
      body,
      [
        {"content-type", "application/json"}
      ]
    )
  end

  defp run_step(socket, {:http_error, status, reason, body}) do
    send_response(socket, status, reason, body, [{"content-type", "application/json"}])
  end

  defp run_step(socket, {:stream, chunks}) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/event-stream\r\n",
      "connection: close\r\n",
      "\r\n"
    ])

    Enum.each(chunks, &:gen_tcp.send(socket, &1))
  end

  defp run_step(socket, {:stream_then_sleep, chunks, milliseconds}) do
    run_step(socket, {:stream, chunks})
    Process.sleep(milliseconds)
  end

  defp run_step(socket, {:chunked_stream_then_sleep, chunks, milliseconds}) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/event-stream\r\n",
      "transfer-encoding: chunked\r\n",
      "connection: close\r\n",
      "\r\n"
    ])

    Enum.each(chunks, fn chunk ->
      :gen_tcp.send(socket, [
        Integer.to_string(byte_size(chunk), 16),
        "\r\n",
        chunk,
        "\r\n"
      ])
    end)

    Process.sleep(milliseconds)
  end

  defp run_step(socket, {:truncated_chunked_stream, chunks}) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/event-stream\r\n",
      "transfer-encoding: chunked\r\n",
      "connection: close\r\n",
      "\r\n"
    ])

    Enum.each(chunks, fn chunk ->
      :gen_tcp.send(socket, [
        Integer.to_string(byte_size(chunk), 16),
        "\r\n",
        chunk,
        "\r\n"
      ])
    end)
  end

  defp run_step(socket, {:malformed_chunked_stream, chunks}) do
    run_step(socket, {:truncated_chunked_stream, chunks})
    :gen_tcp.send(socket, "zz\r\n")
  end

  defp send_response(socket, status, reason, body, headers) do
    header_lines =
      Enum.map(headers, fn {name, value} ->
        [name, ": ", value, "\r\n"]
      end)

    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason,
      "\r\n",
      header_lines,
      "content-length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ])
  end

  defp read_http_request(socket, acc) do
    case complete_http_request?(acc) do
      true ->
        {:ok, acc}

      false ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, chunk} -> read_http_request(socket, acc <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp complete_http_request?(raw) do
    case :binary.split(raw, "\r\n\r\n") do
      [_headers] ->
        false

      [headers, body] ->
        content_length =
          headers
          |> String.split("\r\n")
          |> Enum.find_value(0, fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] ->
                if String.downcase(name) == "content-length" do
                  value |> String.trim() |> String.to_integer()
                end

              _other ->
                nil
            end
          end)

        byte_size(body) >= content_length
    end
  end

  defp parse_http_request(raw) do
    [headers, body] = :binary.split(raw, "\r\n\r\n")
    [request_line | _headers] = String.split(headers, "\r\n")
    [method, path | _rest] = String.split(request_line, " ")
    parsed_headers = parse_headers(headers)
    content_type = Map.get(parsed_headers, "content-type", "")

    %{
      method: method,
      path: path,
      headers: parsed_headers,
      raw_body: body,
      json: json_body(body, content_type),
      multipart: multipart_body(body, content_type)
    }
  end

  defp parse_headers(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> [{String.downcase(name), String.trim(value)}]
        _other -> []
      end
    end)
    |> Map.new()
  end

  defp json_body(body, "application/json" <> _rest), do: Jason.decode!(body)
  defp json_body(_body, _content_type), do: nil

  defp multipart_body(body, content_type) do
    case Regex.run(~r/boundary=("[^"]+"|[^;]+)/, content_type) do
      [_, boundary] ->
        boundary = boundary |> String.trim() |> String.trim("\"")

        body
        |> :binary.split("--" <> boundary, [:global])
        |> Enum.flat_map(&multipart_segment/1)

      _no_boundary ->
        []
    end
  end

  defp multipart_segment(segment) do
    segment = trim_leading_crlf(segment)

    cond do
      segment == "" -> []
      String.starts_with?(segment, "--") -> []
      true -> multipart_part_from_segment(segment)
    end
  end

  defp multipart_part_from_segment(segment) do
    case :binary.split(segment, "\r\n\r\n") do
      [headers, body] ->
        parsed_headers = parse_headers("POST / HTTP/1.1\r\n" <> headers)
        disposition = Map.get(parsed_headers, "content-disposition", "")

        [
          %{
            name: disposition_value(disposition, "name"),
            filename: disposition_value(disposition, "filename"),
            content_type: Map.get(parsed_headers, "content-type"),
            body: trim_trailing_crlf(body)
          }
        ]

      _invalid ->
        []
    end
  end

  defp disposition_value(disposition, key) do
    case Regex.run(~r/#{key}="([^"]*)"/, disposition) do
      [_, value] -> value
      _missing -> nil
    end
  end

  defp trim_leading_crlf(<<"\r\n", rest::binary>>), do: rest
  defp trim_leading_crlf(binary), do: binary

  defp trim_trailing_crlf(binary) do
    size = byte_size(binary)

    if size >= 2 and binary_part(binary, size - 2, 2) == "\r\n" do
      binary_part(binary, 0, size - 2)
    else
      binary
    end
  end
end
