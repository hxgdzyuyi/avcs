defmodule Mix.Tasks.MockManyTurns do
  @moduledoc """
  Mix task for quickly seeding a project sqlite with synthetic turns for local UI/testing.

  Usage:
    mix mock_many_turns /absolute/path/to/.avcs/project.sqlite3 10
  """

  use Mix.Task

  alias Avcs.Storage.SQLite

  @shortdoc "Mock many turns for a project sqlite"
  @max_turn_count 2500
  @max_turn_count_env "MIX_MOCK_TURNS_MAX"
  @completed_ratio 0.9

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    :rand.seed(
      :exsss,
      {
        :erlang.unique_integer([:positive]),
        :erlang.unique_integer([:positive]),
        System.monotonic_time()
      }
    )

    {project_db_path, turn_count} = parse_args(args)
    {summary, thread_id} = seed_mock_turns!(project_db_path, turn_count)

    Mix.shell().info("mock thread created")
    Mix.shell().info("db: #{project_db_path}")
    Mix.shell().info("thread_id: #{thread_id}")
    Mix.shell().info("turn_count: #{summary.turn_count}")
    Mix.shell().info("items_count: #{summary.items_count}")
    :ok
  end

  defp parse_args([project_db_path, turn_count]) do
    db_path = Path.expand(project_db_path)

    unless Path.type(db_path) == :absolute do
      Mix.raise("project_sqlite_path must be an absolute path: #{project_db_path}")
    end

    unless File.exists?(db_path) do
      Mix.raise("project sqlite file not found: #{db_path}")
    end

    case Integer.parse(turn_count) do
      {count, ""} ->
        validate_turn_count(count, db_path)

      _ ->
        Mix.raise("turn_count must be an integer: #{turn_count}")
    end

    {db_path, String.to_integer(turn_count)}
  end

  defp parse_args(_args) do
    Mix.raise("""
    invalid args

    Usage:
      mix mock_many_turns <project_sqlite_path> <turn_count>
    """)
  end

  defp validate_turn_count(count, path) do
    max_turn_count = configured_max_turn_count()

    cond do
      count <= 0 ->
        Mix.raise("turn_count must be > 0: #{count}")

      count > max_turn_count ->
        Mix.raise(
          "turn_count exceeds max(#{max_turn_count}) for path #{path}: #{count}\n" <>
            "Set #{_env_key()} to a larger integer to override."
        )

      true ->
        :ok
    end
  end

  defp configured_max_turn_count do
    case System.get_env(_env_key()) do
      nil ->
        @max_turn_count

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> @max_turn_count
        end
    end
  end

  defp _env_key, do: @max_turn_count_env

  defp seed_mock_turns!(project_db_path, turn_count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    summary =
      case SQLite.with_db(project_db_path, fn db ->
             SQLite.transaction!(db, fn ->
               ensure_schema!(db)

               thread_id = Ecto.UUID.generate()
               thread_title = "Mock Thread #{DateTime.to_iso8601(now)}"
               thread_at = timestamp(now, 0)

               SQLite.run!(
                 db,
                 """
                 INSERT INTO threads (id, title, status, created_at, updated_at)
                 VALUES (?, ?, ?, ?, ?)
                 """,
                 [thread_id, thread_title, "idle", thread_at, thread_at]
               )

               inserted = do_insert_turns(db, thread_id, turn_count, now)

               SQLite.run!(
                 db,
                 "UPDATE threads SET updated_at = ? WHERE id = ?",
                 [timestamp(now, turn_count * 700), thread_id]
               )

               %{
                 thread_id: thread_id,
                 items_count: inserted.items_count,
                 turn_count: inserted.turn_count
               }
             end)
           end) do
        {:ok, summary} ->
          summary

        {:error, reason} ->
          Mix.raise(reason)
      end

    {summary, summary.thread_id}
  end

  defp do_insert_turns(db, thread_id, turn_count, now) do
    Enum.reduce(1..turn_count, %{items_count: 0, turn_count: 0}, fn index, acc ->
      turn_at = timestamp(now, index * 720 + :rand.uniform(200))
      turn_id = Ecto.UUID.generate()
      turn_status = random_turn_status()
      user_text = random_user_message(index)

      SQLite.run!(
        db,
        """
        INSERT INTO turns (
          id, thread_id, status, user_text, model, effort, approval_policy,
          sandbox_mode, completed_at, error, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          turn_id,
          thread_id,
          turn_status,
          user_text,
          nil,
          nil,
          nil,
          nil,
          if(turn_status == "completed", do: turn_at, else: nil),
          if(turn_status == "failed", do: random_turn_error(index), else: nil),
          turn_at,
          turn_at
        ]
      )

      item_count =
        insert_mock_items(
          db,
          thread_id,
          turn_id,
          index,
          now,
          index * 720 + :rand.uniform(200),
          turn_status
        )

      if rem(index, 10) == 0 do
        Mix.shell().info("inserted #{index}/#{turn_count} turns")
      end

      %{items_count: acc.items_count + item_count, turn_count: acc.turn_count + 1}
    end)
  end

  defp insert_mock_items(db, thread_id, turn_id, index, now, turn_time_ms, turn_status) do
    user_item_time = timestamp(now, turn_time_ms)

    user_item_payload =
      Jason.encode!(%{
        "source" => "mock",
        "mock_index" => index,
        "asset_ids" => [],
        "role" => "user"
      })

    SQLite.run!(
      db,
      """
      INSERT INTO items (
        id, turn_id, thread_id, remote_item_id, type, role, content, payload,
        status, created_at, updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        Ecto.UUID.generate(),
        turn_id,
        thread_id,
        nil,
        "user_message",
        "user",
        random_user_message(index),
        user_item_payload,
        item_status(turn_status),
        user_item_time,
        user_item_time
      ]
    )

    extra_count = random_item_count()

    inserted =
      Enum.reduce(1..extra_count, 1, fn seq, acc ->
        assistant_time = timestamp(now, turn_time_ms + seq * 60)

        payload =
          Jason.encode!(%{
            "source" => "mock",
            "mock_index" => index,
            "asset_ids" => [],
            "seq" => seq,
            "role" => "assistant"
          })

        SQLite.run!(
          db,
          """
          INSERT INTO items (
            id, turn_id, thread_id, remote_item_id, type, role, content, payload,
            status, created_at, updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            Ecto.UUID.generate(),
            turn_id,
            thread_id,
            nil,
            random_item_type(),
            "assistant",
            random_assistant_message(index, seq),
            payload,
            item_status(turn_status),
            assistant_time,
            assistant_time
          ]
        )

        acc + 1
      end)

    if turn_status == "failed" do
      err_time = timestamp(now, turn_time_ms + (extra_count + 1) * 80)
      error_payload = Jason.encode!(%{"source" => "mock", "mock_index" => index, "fatal" => true})

      SQLite.run!(
        db,
        """
        INSERT INTO items (
          id, turn_id, thread_id, remote_item_id, type, role, content, payload,
          status, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          Ecto.UUID.generate(),
          turn_id,
          thread_id,
          nil,
          "error",
          "system",
          random_turn_error(index),
          error_payload,
          "failed",
          err_time,
          err_time
        ]
      )

      inserted + 1
    else
      inserted
    end
  end

  defp item_status("failed"), do: "failed"
  defp item_status(_), do: "completed"

  defp random_turn_status do
    if :rand.uniform() <= @completed_ratio do
      "completed"
    else
      "failed"
    end
  end

  defp random_turn_error(index) do
    [
      "Mock model error ##{index}: timeout while resolving scene",
      "Mock tool error ##{index}: image engine transient issue",
      "Mock asset fetch warning ##{index}: no usable source found"
    ]
    |> Enum.random()
  end

  defp random_item_count do
    :rand.uniform(3)
  end

  defp random_user_message(index) do
    base = [
      "Draft a poster",
      "Adjust composition",
      "Try a warmer tone",
      "Remove background noise",
      "Make this clearer",
      "Generate a variation",
      "Add concise labels",
      "Increase saturation",
      "Shorten text blocks",
      "Try editorial mood",
      "Check spacing and hierarchy"
    ]

    words = Enum.random(8..20)

    Enum.map_join(1..words, " ", fn _ -> Enum.random(base) end) <>
      " (#{index})"
  end

  defp random_assistant_message(index, seq) do
    prefix = Enum.random(["Done:", "Noted:", "Applied:", "Result:", "Suggestion:", "Analysis:"])

    suffix =
      Enum.random([
        "generated mixed style output.",
        "adjusted for stable layout.",
        "kept contrast balanced.",
        "with compact structure.",
        "and concise commentary."
      ])

    phrase = String.duplicate("mocked ", Enum.random(1..4))
    "#{prefix} #{phrase}##{index}-#{seq} #{suffix}"
  end

  defp random_item_type do
    case :rand.uniform(20) do
      n when n <= 15 ->
        "assistant_message"

      _ ->
        "tool_result"
    end
  end

  defp ensure_schema!(db) do
    Enum.each(["threads", "turns", "items"], &ensure_table_exists!(db, &1))
  end

  defp ensure_table_exists!(db, table) do
    if is_nil(
         SQLite.scalar!(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?", [table])
       ) do
      raise RuntimeError, "database missing required table: #{table}"
    end
  end

  defp timestamp(base, offset_ms) do
    base
    |> DateTime.add(offset_ms, :millisecond)
    |> DateTime.to_iso8601()
  end
end
