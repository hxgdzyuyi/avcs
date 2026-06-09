defmodule Avcs.Agent.AvcsAgentClientTest do
  use ExUnit.Case, async: false

  alias Avcs.Agent.AvcsAgentClient
  alias Avcs.HTTPTestServer

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
       )

  setup do
    env_keys = [
      :avcs_agent_stream_retry_attempts,
      :avcs_agent_stream_retry_backoff_ms,
      :avcs_agent_request_timeout_ms,
      :avcs_agent_connect_timeout_ms
    ]

    previous = Enum.map(env_keys, &{&1, Application.fetch_env(:avcs, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:avcs, key, value)
        {key, :error} -> Application.delete_env(:avcs, key)
      end)
    end)

    :ok
  end

  test "sends Vercel referenced images through chat completions for chat image models" do
    with_temp_image("reference", fn reference_path ->
      response_body = chat_image_response("chat-image-response")
      server = start_http_server!(response_body)

      try do
        assert {:ok, result} =
                 AvcsAgentClient.generate_image("Use the reference",
                   base_url: "http://127.0.0.1:#{server.port}/ai-gateway.vercel.sh/v1",
                   api_key: "test-key",
                   image_model: "google/gemini-3.1-flash-image-preview",
                   reference_images: [
                     %{
                       asset_id: "asset-1",
                       path: reference_path,
                       file_name: "reference.png",
                       mime_type: "image/png"
                     }
                   ],
                   size: "1024x1536",
                   quality: "high",
                   output_format: "png"
                 )

        assert result.raw_id == "chat-image-response"
        assert [%{base64: base64, mime_type: "image/png"}] = result.images
        assert Base.decode64!(base64) == @png

        assert_receive {:http_request, request}, 1_000
        assert request.method == "POST"
        assert request.path == "/ai-gateway.vercel.sh/v1/chat/completions"
        assert request.multipart == []

        assert request.json["model"] == "google/gemini-3.1-flash-image-preview"
        assert request.json["modalities"] == ["image"]
        assert request.json["stream"] == false
        assert request.json["n"] == 1

        [%{"content" => content, "role" => "user"}] = request.json["messages"]
        assert Enum.any?(content, &(&1["type"] == "text" and &1["text"] =~ "Use the reference"))
        assert Enum.any?(content, &(&1["type"] == "text" and &1["text"] =~ "size: 1024x1536"))
        assert Enum.any?(content, &(&1["type"] == "text" and &1["text"] =~ "quality: high"))
        assert Enum.any?(content, &(&1["type"] == "text" and &1["text"] =~ "output_format: png"))

        assert Enum.any?(
                 content,
                 &(&1["type"] == "image_url" and
                     String.starts_with?(&1["image_url"]["url"], "data:image/png;base64,"))
               )
      after
        stop_http_server(server)
      end
    end)
  end

  test "sends Vercel text-only generation through chat completions for Gemini image models" do
    response_body = chat_image_response("chat-image-generation-response")
    server = start_http_server!(response_body)

    try do
      assert {:ok, result} =
               AvcsAgentClient.generate_image("Generate a sunset image",
                 base_url: "http://127.0.0.1:#{server.port}/ai-gateway.vercel.sh/v1",
                 api_key: "test-key",
                 image_model: "google/gemini-3.1-flash-image-preview",
                 size: "1024x1536",
                 quality: "high"
               )

      assert result.raw_id == "chat-image-generation-response"
      assert [%{base64: base64, mime_type: "image/png"}] = result.images
      assert Base.decode64!(base64) == @png

      assert_receive {:http_request, request}, 1_000
      assert request.method == "POST"
      assert request.path == "/ai-gateway.vercel.sh/v1/chat/completions"
      assert request.multipart == []

      assert request.json["model"] == "google/gemini-3.1-flash-image-preview"
      assert request.json["modalities"] == ["image"]
      assert request.json["stream"] == false
      assert request.json["n"] == 1

      [%{"content" => content, "role" => "user"}] = request.json["messages"]
      assert is_binary(content)
      assert content =~ "Generate a sunset image"
      assert content =~ "size: 1024x1536"
      assert content =~ "quality: high"
    after
      stop_http_server(server)
    end
  end

  test "rejects Vercel referenced images for image-only OpenAI image models" do
    with_temp_image("reference", fn reference_path ->
      assert {:error, message} =
               AvcsAgentClient.generate_image("Use the reference",
                 base_url: "https://ai-gateway.vercel.sh/v1",
                 api_key: "test-key",
                 image_model: "openai/gpt-image-2",
                 reference_images: [
                   %{
                     asset_id: "asset-1",
                     path: reference_path,
                     file_name: "reference.png",
                     mime_type: "image/png"
                   }
                 ]
               )

      assert message =~ "does not support reference images"
      assert message =~ "openai/gpt-image-2"
      assert message =~ "/images/generations"
    end)
  end

  test "sends Vercel text-only image generation through images endpoint for image-only models" do
    response_body = image_api_response("vercel-image-only-generation-response")
    server = start_http_server!(response_body)

    try do
      assert {:ok, result} =
               AvcsAgentClient.generate_image("Draw a red balloon",
                 base_url: "http://127.0.0.1:#{server.port}/ai-gateway.vercel.sh/v1",
                 api_key: "test-key",
                 image_model: "openai/gpt-image-2",
                 size: "1024x1024",
                 quality: "medium"
               )

      assert result.raw_id == "vercel-image-only-generation-response"

      assert_receive {:http_request, request}, 1_000
      assert request.method == "POST"
      assert request.path == "/ai-gateway.vercel.sh/v1/images/generations"

      assert request.json["model"] == "openai/gpt-image-2"
      assert request.json["prompt"] == "Draw a red balloon"
      assert request.json["n"] == 1
      assert request.json["size"] == "1024x1024"
      assert request.json["quality"] == "medium"
      refute Map.has_key?(request.json, "response_format")
    after
      stop_http_server(server)
    end
  end

  test "sends mask image through image edits transport" do
    with_temp_image("reference", fn reference_path ->
      with_temp_image("mask", fn mask_path ->
        response_body = image_api_response("mask-edit-response")
        server = start_http_server!(response_body)

        try do
          assert {:ok, result} =
                   AvcsAgentClient.generate_image("Edit with a mask",
                     base_url: "http://127.0.0.1:#{server.port}/v1",
                     api_key: "test-key",
                     image_model: "openai/gpt-image-2",
                     reference_images: [
                       %{
                         asset_id: "asset-1",
                         path: reference_path,
                         file_name: "reference.png",
                         mime_type: "image/png"
                       }
                     ],
                     mask_image: %{
                       asset_id: "mask-1",
                       path: mask_path,
                       file_name: "mask.png",
                       mime_type: "image/png"
                     }
                   )

          assert result.raw_id == "mask-edit-response"

          assert_receive {:http_request, request}, 1_000
          assert request.method == "POST"
          assert request.path == "/v1/images/edits"

          image = multipart_part(request.multipart, "image[]")
          assert image.filename == "reference.png"
          assert image.body == @png

          mask = multipart_part(request.multipart, "mask")
          assert mask.filename == "mask.png"
          assert mask.content_type == "image/png"
          assert mask.body == @png
        after
          stop_http_server(server)
        end
      end)
    end)
  end

  test "sends text-only image generation through image generations transport" do
    response_body = image_api_response("generation-response")
    server = start_http_server!(response_body)

    try do
      assert {:ok, result} =
               AvcsAgentClient.generate_image("Draw a red balloon",
                 base_url: "http://127.0.0.1:#{server.port}/v1",
                 api_key: "test-key",
                 image_model: "openai/gpt-image-2",
                 size: "1024x1024",
                 quality: "medium"
               )

      assert result.raw_id == "generation-response"

      assert_receive {:http_request, request}, 1_000
      assert request.method == "POST"
      assert request.path == "/v1/images/generations"

      assert request.json["model"] == "openai/gpt-image-2"
      assert request.json["prompt"] == "Draw a red balloon"
      assert request.json["n"] == 1
      assert request.json["size"] == "1024x1024"
      assert request.json["quality"] == "medium"
      refute Map.has_key?(request.json, "response_format")
    after
      stop_http_server(server)
    end
  end

  test "sends referenced images through explicit chat completions image transport" do
    with_temp_image("reference", fn reference_path ->
      response_body = chat_image_response("chat-image-response")
      server = start_http_server!(response_body)

      try do
        assert {:ok, result} =
                 AvcsAgentClient.generate_image("Use the reference",
                   base_url: "http://127.0.0.1:#{server.port}/v1",
                   api_key: "test-key",
                   image_model: "google/gemini-3-pro-image",
                   image_transport: :chat_completions,
                   reference_images: [
                     %{
                       asset_id: "asset-1",
                       path: reference_path,
                       file_name: "reference.png",
                       mime_type: "image/png"
                     }
                   ],
                   size: "1024x1536",
                   quality: "high"
                 )

        assert result.raw_id == "chat-image-response"
        assert [%{base64: base64, mime_type: "image/png"}] = result.images
        assert Base.decode64!(base64) == @png

        assert_receive {:http_request, request}, 1_000
        assert request.method == "POST"
        assert request.path == "/v1/chat/completions"

        assert request.json["model"] == "google/gemini-3-pro-image"
        assert request.json["modalities"] == ["image"]
        assert request.json["stream"] == false

        [%{"content" => content, "role" => "user"}] = request.json["messages"]
        assert Enum.any?(content, &(&1["type"] == "text" and &1["text"] =~ "Use the reference"))
        assert Enum.any?(content, &(&1["type"] == "text" and &1["text"] =~ "size: 1024x1536"))

        assert Enum.any?(
                 content,
                 &(&1["type"] == "image_url" and
                     String.starts_with?(&1["image_url"]["url"], "data:image/png;base64,"))
               )
      after
        stop_http_server(server)
      end
    end)
  end

  test "image API errors keep generic gateway wording" do
    with_temp_image("reference", fn reference_path ->
      response_body =
        Jason.encode!(%{
          "error" => %{
            "message" => "Invalid image input"
          }
        })

      server = start_http_server!(response_body, status: 400, reason: "Bad Request")

      try do
        assert {:error, message} =
                 AvcsAgentClient.generate_image("Use the reference",
                   base_url: "http://127.0.0.1:#{server.port}/v1",
                   api_key: "test-key",
                   image_model: "openai/gpt-image-2",
                   reference_images: [
                     %{
                       asset_id: "asset-1",
                       path: reference_path,
                       file_name: "reference.png",
                       mime_type: "image/png"
                     }
                   ]
                 )

        assert message == "AI Gateway request failed with HTTP 400: Invalid image input"
        refute message =~ "vision-capable"
      after
        stop_http_server(server)
      end
    end)
  end

  test "chat image transport errors keep chat model guidance" do
    with_temp_image("reference", fn reference_path ->
      response_body =
        Jason.encode!(%{
          "error" => %{
            "message" => "Invalid image content"
          }
        })

      server = start_http_server!(response_body, status: 400, reason: "Bad Request")

      try do
        assert {:error, message} =
                 AvcsAgentClient.generate_image("Use the reference",
                   base_url: "http://127.0.0.1:#{server.port}/v1",
                   api_key: "test-key",
                   image_model: "google/gemini-3-pro-image",
                   image_transport: :chat_completions,
                   reference_images: [
                     %{
                       asset_id: "asset-1",
                       path: reference_path,
                       file_name: "reference.png",
                       mime_type: "image/png"
                     }
                   ]
                 )

        assert message =~ "Select a vision-capable OpenAI-compatible chat model"
        assert message =~ "HTTP 400: Invalid image content"
      after
        stop_http_server(server)
      end
    end)
  end

  test "retries failed connect before stream commits" do
    Application.put_env(:avcs, :avcs_agent_stream_retry_attempts, 2)
    Application.put_env(:avcs, :avcs_agent_stream_retry_backoff_ms, [150])
    Application.put_env(:avcs, :avcs_agent_connect_timeout_ms, 50)

    port = HTTPTestServer.reserve_port()

    server =
      HTTPTestServer.start!([{:stream, successful_text_stream("Recovered.")}],
        port: port,
        delay_ms: 40
      )

    try do
      assert {:ok, result} =
               AvcsAgentClient.chat_completion_stream(
                 [%{"role" => "user", "content" => "Recover after failed connect"}],
                 [],
                 stream_opts(port),
                 stream_event_handler(self()),
                 fn -> false end
               )

      assert result.assistant_text == "Recovered."
      assert result.tool_calls == []
      assert result.remote_turn_id == "chatcmpl-test"
      assert result.remote_model == "fake-text-model"

      assert_receive {:stream_event, {:assistant_delta, "Recovered.", _chunk}}, 1_000
      assert_receive {:http_request, request}, 1_000
      assert request.path == "/v1/chat/completions"
      assert request.json["stream"] == true
    after
      HTTPTestServer.stop(server)
    end
  end

  test "retries timeout before first stream chunk" do
    Application.put_env(:avcs, :avcs_agent_stream_retry_attempts, 2)
    Application.put_env(:avcs, :avcs_agent_stream_retry_backoff_ms, [10])
    Application.put_env(:avcs, :avcs_agent_request_timeout_ms, 40)

    server =
      HTTPTestServer.start!([
        {:sleep, 120},
        {:stream, successful_text_stream("Recovered after timeout.")}
      ])

    try do
      assert {:ok, result} =
               AvcsAgentClient.chat_completion_stream(
                 [%{"role" => "user", "content" => "Recover after timeout"}],
                 [],
                 stream_opts(server.port),
                 stream_event_handler(self()),
                 fn -> false end
               )

      assert result.assistant_text == "Recovered after timeout."
      assert_receive {:http_request, first_request}, 1_000
      assert_receive {:http_request, second_request}, 1_000
      assert first_request.path == "/v1/chat/completions"
      assert second_request.path == "/v1/chat/completions"
    after
      HTTPTestServer.stop(server)
    end
  end

  test "does not retry non-retryable stream HTTP errors" do
    Application.put_env(:avcs, :avcs_agent_stream_retry_attempts, 3)
    Application.put_env(:avcs, :avcs_agent_stream_retry_backoff_ms, [10, 10])

    for {status, reason} <- [{400, "Bad Request"}, {401, "Unauthorized"}] do
      body = Jason.encode!(%{"error" => %{"message" => "Request rejected #{status}"}})
      server = HTTPTestServer.start!([{:http_error, status, reason, body}])

      try do
        assert {:error, message} =
                 AvcsAgentClient.chat_completion_stream(
                   [%{"role" => "user", "content" => "Do not retry"}],
                   [],
                   stream_opts(server.port),
                   stream_event_handler(self()),
                   fn -> false end
                 )

        assert message ==
                 "AI Gateway request failed with HTTP #{status}: Request rejected #{status}"

        assert_receive {:http_request, request}, 1_000
        assert request.path == "/v1/chat/completions"
        refute_receive {:http_request, _request}, 100
      after
        HTTPTestServer.stop(server)
      end
    end
  end

  test "does not retry after assistant text stream commits" do
    Application.put_env(:avcs, :avcs_agent_stream_retry_attempts, 2)
    Application.put_env(:avcs, :avcs_agent_stream_retry_backoff_ms, [10])
    Application.put_env(:avcs, :avcs_agent_request_timeout_ms, 1000)
    partial_text = "Partial text." <> String.duplicate("x", 100_000)

    server =
      HTTPTestServer.start!([
        {:chunked_stream_then_sleep, [text_stream_chunk(partial_text)], 2_000},
        {:stream, successful_text_stream("Retried text.")}
      ])

    try do
      assert {:error, reason} =
               AvcsAgentClient.chat_completion_stream(
                 [%{"role" => "user", "content" => "Do not replay text"}],
                 [],
                 stream_opts(server.port),
                 stream_event_handler(self()),
                 fn -> false end
               )

      assert timeout_reason?(reason)
      assert_receive {:stream_event, {:assistant_delta, ^partial_text, _chunk}}, 1_000
      assert_receive {:http_request, request}, 1_000
      assert request.path == "/v1/chat/completions"
      refute_receive {:http_request, _request}, 150
    after
      HTTPTestServer.stop(server)
    end
  end

  test "does not retry after tool call delta stream commits" do
    Application.put_env(:avcs, :avcs_agent_stream_retry_attempts, 2)
    Application.put_env(:avcs, :avcs_agent_stream_retry_backoff_ms, [10])
    Application.put_env(:avcs, :avcs_agent_request_timeout_ms, 1000)
    arguments = Jason.encode!(%{"prompt" => String.duplicate("tool", 25_000)})

    server =
      HTTPTestServer.start!([
        {:chunked_stream_then_sleep, [tool_call_stream_chunk(arguments)], 2_000},
        {:stream, successful_text_stream("Retried tool call.")}
      ])

    try do
      assert {:error, reason} =
               AvcsAgentClient.chat_completion_stream(
                 [%{"role" => "user", "content" => "Do not replay tool call"}],
                 [],
                 stream_opts(server.port),
                 stream_event_handler(self()),
                 fn -> false end
               )

      assert timeout_reason?(reason)
      refute_receive {:stream_event, _event}, 100
      assert_receive {:http_request, request}, 1_000
      assert request.path == "/v1/chat/completions"
      refute_receive {:http_request, _request}, 150
    after
      HTTPTestServer.stop(server)
    end
  end

  test "traces streaming chat completions with safe metadata" do
    with_trace_project(fn project, thread_id, turn_id, trace_context ->
      server = HTTPTestServer.start!([{:stream, successful_text_stream("Traced response.")}])
      prompt = "do-not-leak-vercel-trace-prompt"

      try do
        assert {:ok, result} =
                 AvcsAgentClient.chat_completion_stream(
                   [%{"role" => "user", "content" => prompt}],
                   [],
                   stream_opts(server.port) ++ [trace_context: trace_context],
                   stream_event_handler(self()),
                   fn -> false end
                 )

        assert result.assistant_text == "Traced response."
        assert_receive {:http_request, _request}, 1_000

        {:ok, events} = Avcs.Trace.list_events(project, thread_id, turn_id: turn_id)
        vercel_events = Enum.filter(events, &(&1["scope"] == "vercel_api"))

        assert request_sent =
                 Enum.find(vercel_events, &(&1["event_name"] == "request_sent"))

        assert request_sent["status"] == "sent"
        assert get_in(request_sent, ["payload", "transport"]) == "sse"
        assert get_in(request_sent, ["payload", "method"]) == "POST"
        assert get_in(request_sent, ["payload", "endpoint"]) == "/v1/chat/completions"
        assert get_in(request_sent, ["payload", "model"]) == "fake-text-model"
        assert get_in(request_sent, ["payload", "stream"]) == true
        assert get_in(request_sent, ["payload", "request_summary", "message_count"]) == 1
        assert get_in(request_sent, ["payload", "request_summary", "tool_count"]) == 0

        assert is_integer(
                 get_in(request_sent, ["payload", "request_summary", "request_size_bytes"])
               )

        assert response_received =
                 Enum.find(
                   vercel_events,
                   &(&1["event_name"] == "response_received" and &1["status"] == "ok")
                 )

        assert get_in(response_received, ["payload", "response_summary", "http_status"]) == 200

        assert get_in(
                 response_received,
                 ["payload", "response_summary", "remote_response_id"]
               ) == "chatcmpl-test"

        assert get_in(response_received, ["payload", "response_summary", "response_model"]) ==
                 "fake-text-model"

        encoded = Jason.encode!(vercel_events)
        refute encoded =~ prompt
        refute encoded =~ "test-key"
        refute String.downcase(encoded) =~ "authorization"
      after
        HTTPTestServer.stop(server)
      end
    end)
  end

  test "traces stream retry attempts before commit" do
    Application.put_env(:avcs, :avcs_agent_stream_retry_attempts, 2)
    Application.put_env(:avcs, :avcs_agent_stream_retry_backoff_ms, [10])
    Application.put_env(:avcs, :avcs_agent_request_timeout_ms, 40)

    with_trace_project(fn project, thread_id, turn_id, trace_context ->
      server =
        HTTPTestServer.start!([
          {:sleep, 120},
          {:stream, successful_text_stream("Recovered with trace.")}
        ])

      try do
        assert {:ok, result} =
                 AvcsAgentClient.chat_completion_stream(
                   [%{"role" => "user", "content" => "Retry trace"}],
                   [],
                   stream_opts(server.port) ++ [trace_context: trace_context],
                   stream_event_handler(self()),
                   fn -> false end
                 )

        assert result.assistant_text == "Recovered with trace."
        assert_receive {:http_request, _first_request}, 1_000
        assert_receive {:http_request, _second_request}, 1_000

        {:ok, events} = Avcs.Trace.list_events(project, thread_id, turn_id: turn_id)
        vercel_events = Enum.filter(events, &(&1["scope"] == "vercel_api"))

        assert timeout_event =
                 Enum.find(vercel_events, &(&1["event_name"] == "request_timeout"))

        assert timeout_event["status"] == "timeout"
        assert get_in(timeout_event, ["payload", "attempt"]) == 1
        assert get_in(timeout_event, ["payload", "max_attempts"]) == 2
        assert get_in(timeout_event, ["payload", "error_summary", "retryable"]) == true

        assert success_event =
                 Enum.find(
                   vercel_events,
                   &(&1["event_name"] == "response_received" and &1["status"] == "ok")
                 )

        assert get_in(success_event, ["payload", "attempt"]) == 2
        assert get_in(success_event, ["payload", "max_attempts"]) == 2
      after
        HTTPTestServer.stop(server)
      end
    end)
  end

  test "traces non-2xx stream responses as bounded errors" do
    with_trace_project(fn project, thread_id, turn_id, trace_context ->
      body = Jason.encode!(%{"error" => %{"message" => "Invalid request for trace"}})
      server = HTTPTestServer.start!([{:http_error, 400, "Bad Request", body}])

      try do
        assert {:error, message} =
                 AvcsAgentClient.chat_completion_stream(
                   [%{"role" => "user", "content" => "Bad trace"}],
                   [],
                   stream_opts(server.port) ++ [trace_context: trace_context],
                   stream_event_handler(self()),
                   fn -> false end
                 )

        assert message == "AI Gateway request failed with HTTP 400: Invalid request for trace"
        assert_receive {:http_request, _request}, 1_000

        {:ok, events} = Avcs.Trace.list_events(project, thread_id, turn_id: turn_id)

        assert error_event =
                 Enum.find(
                   events,
                   &(&1["scope"] == "vercel_api" and
                       &1["event_name"] == "response_received" and &1["status"] == "error")
                 )

        assert get_in(error_event, ["payload", "response_summary", "http_status"]) == 400

        assert get_in(error_event, ["payload", "response_summary", "error_message"]) ==
                 "Invalid request for trace"
      after
        HTTPTestServer.stop(server)
      end
    end)
  end

  test "traces image generation without storing prompt or base64" do
    with_trace_project(fn project, thread_id, turn_id, trace_context ->
      prompt = "do-not-leak-image-prompt"
      response_body = image_api_response("image-trace-response")
      server = start_http_server!(response_body)

      try do
        assert {:ok, result} =
                 AvcsAgentClient.generate_image(prompt,
                   base_url: "http://127.0.0.1:#{server.port}/v1",
                   api_key: "test-key",
                   image_model: "openai/gpt-image-2",
                   trace_context: trace_context
                 )

        assert result.raw_id == "image-trace-response"
        assert_receive {:http_request, request}, 1_000
        assert request.path == "/v1/images/generations"

        {:ok, events} = Avcs.Trace.list_events(project, thread_id, turn_id: turn_id)

        assert response_event =
                 Enum.find(
                   events,
                   &(&1["scope"] == "vercel_api" and
                       &1["event_name"] == "response_received" and &1["status"] == "ok")
                 )

        assert get_in(response_event, ["payload", "endpoint"]) == "/v1/images/generations"

        assert get_in(response_event, ["payload", "response_summary", "remote_response_id"]) ==
                 "image-trace-response"

        assert get_in(response_event, ["payload", "response_summary", "image_count"]) == 1

        encoded = Jason.encode!(Enum.filter(events, &(&1["scope"] == "vercel_api")))
        refute encoded =~ prompt
        refute encoded =~ Base.encode64(@png)
        refute encoded =~ "data:image"
      after
        stop_http_server(server)
      end
    end)
  end

  defp image_api_response(id) do
    Jason.encode!(%{
      "id" => id,
      "data" => [
        %{
          "b64_json" => Base.encode64(@png)
        }
      ]
    })
  end

  defp chat_image_response(id) do
    Jason.encode!(%{
      "id" => id,
      "model" => "openai/gpt-image-2",
      "choices" => [
        %{
          "message" => %{
            "images" => [
              %{
                "image_url" => %{
                  "url" => "data:image/png;base64,#{Base.encode64(@png)}"
                }
              }
            ]
          }
        }
      ]
    })
  end

  defp successful_text_stream(text) do
    [text_stream_chunk(text), HTTPTestServer.sse_done()]
  end

  defp text_stream_chunk(text) do
    HTTPTestServer.sse_chunk(%{
      "id" => "chatcmpl-test",
      "model" => "fake-text-model",
      "choices" => [
        %{
          "delta" => %{
            "content" => text
          }
        }
      ]
    })
  end

  defp tool_call_stream_chunk(arguments) do
    HTTPTestServer.sse_chunk(%{
      "id" => "chatcmpl-test",
      "model" => "fake-text-model",
      "choices" => [
        %{
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "call-1",
                "type" => "function",
                "function" => %{
                  "name" => "image_gen",
                  "arguments" => arguments
                }
              }
            ]
          }
        }
      ]
    })
  end

  defp stream_opts(port) do
    [
      base_url: "http://127.0.0.1:#{port}/v1",
      api_key: "test-key",
      model: "fake-text-model"
    ]
  end

  defp stream_event_handler(parent) do
    fn event -> send(parent, {:stream_event, event}) end
  end

  defp with_trace_project(fun) do
    project_dir =
      Path.join(
        System.tmp_dir!(),
        "avcs-agent-client-trace-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(project_dir)

    try do
      {:ok, project} = Avcs.Projects.open_project(project_dir)
      {:ok, thread} = Avcs.Threads.create_thread(project, "Vercel API trace")

      {:ok, created} =
        Avcs.Turns.create_user_turn(project, thread["id"], "Trace Vercel API", [])

      turn_id = created["turn"]["id"]

      trace_context = %{
        project: project,
        thread_id: thread["id"],
        turn_id: turn_id,
        remote_thread_id: "avcs-agent-thread-trace",
        remote_turn_id: "avcs-agent-turn-trace",
        model: "fake-text-model"
      }

      fun.(project, thread["id"], turn_id, trace_context)
    after
      File.rm_rf!(project_dir)
    end
  end

  defp timeout_reason?(:timeout), do: true
  defp timeout_reason?(reason) when is_binary(reason), do: String.contains?(reason, "timeout")
  defp timeout_reason?(_reason), do: false

  defp with_temp_image(prefix, fun) do
    path =
      Path.join(System.tmp_dir!(), "avcs-#{prefix}-#{System.unique_integer([:positive])}.png")

    File.write!(path, @png)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp start_http_server!(response_body, opts \\ []) do
    parent = self()
    status = Keyword.get(opts, :status, 200)
    reason = Keyword.get(opts, :reason, "OK")

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, raw_request} = read_http_request(socket, "")
        send(parent, {:http_request, parse_http_request(raw_request)})

        response = [
          "HTTP/1.1 ",
          Integer.to_string(status),
          " ",
          reason,
          "\r\n",
          "content-type: application/json\r\n",
          "content-length: ",
          Integer.to_string(byte_size(response_body)),
          "\r\n",
          "connection: close\r\n",
          "\r\n",
          response_body
        ]

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    %{port: port, task: task, listen_socket: listen_socket}
  end

  defp stop_http_server(%{task: task, listen_socket: listen_socket}) do
    :gen_tcp.close(listen_socket)

    case Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, _result} -> :ok
      _result -> :ok
    end
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

  defp multipart_part(parts, name) do
    Enum.find(parts, &(&1.name == name))
  end
end
