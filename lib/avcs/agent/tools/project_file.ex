defmodule Avcs.Agent.Tools.ProjectFile do
  @moduledoc false

  @max_text_file_bytes 1_048_576
  @max_write_bytes 10 * 1_048_576
  @denied_extensions ~w(.sqlite .sqlite3 .db)
  @secret_name_pattern ~r/(^\.env(?:\.|$)|secret|credential|token|api[_-]?key|password)/i

  def max_text_file_bytes, do: @max_text_file_bytes
  def max_write_bytes, do: @max_write_bytes

  def decode_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _decoded} ->
        {:error, error(:invalid_arguments, "Tool arguments must be a JSON object")}

      {:error, reason} ->
        {:error, error(:invalid_arguments, Exception.message(reason))}
    end
  end

  def decode_arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  def decode_arguments(_arguments),
    do: {:error, error(:invalid_arguments, "Tool arguments are invalid")}

  def string_arg(arguments, key, default \\ nil) do
    case value(arguments, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: default, else: value

      nil ->
        default

      value ->
        to_string(value)
    end
  end

  def integer_arg(arguments, key, default, min_value, max_value) do
    value(arguments, key)
    |> parse_integer(default)
    |> max(min_value)
    |> min(max_value)
  end

  def boolean_arg(arguments, key, default \\ false) do
    case value(arguments, key) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(String.trim(value)) in ["1", "true", "yes"]
      nil -> default
      _value -> default
    end
  end

  def error(code, message, details \\ nil) do
    %{code: to_string(code), message: message, details: details}
  end

  def resolve_existing(project, path, opts \\ []) do
    kind = Keyword.get(opts, :kind, :any)
    allow_symlink = Keyword.get(opts, :allow_symlink, false)
    scopes = Keyword.get(opts, :scopes, [:project])

    with {:ok, root} <- project_root(project),
         {:ok, addressed} <- addressed_path(root, path || "."),
         :ok <- ensure_inside_project(addressed, root),
         {:ok, stat} <- lstat(addressed),
         {:ok, relative_path} <- project_relative_path(project, addressed),
         :ok <- ensure_safe_relative(relative_path),
         :ok <- ensure_scope(relative_path, scopes),
         {:ok, canonical_path} <- canonical_existing_path(root, relative_path),
         canonical_relative_path = relative_path,
         :ok <- ensure_safe_relative(canonical_relative_path),
         :ok <- ensure_symlink_allowed(stat.type, allow_symlink),
         :ok <- ensure_kind(stat.type, kind) do
      {:ok,
       %{
         path: addressed,
         canonical_path: canonical_path,
         relative_path: relative_path,
         canonical_relative_path: canonical_relative_path,
         type: stat.type,
         size: stat.size,
         mtime: stat.mtime
       }}
    end
  end

  def resolve_target(project, path, opts \\ []) do
    scopes = Keyword.get(opts, :scopes, [:work, :output])

    with {:ok, root} <- project_root(project),
         {:ok, addressed} <- addressed_path(root, path),
         :ok <- ensure_inside_project(addressed, root),
         {:ok, relative_path} <- project_relative_path(project, addressed),
         :ok <- ensure_safe_relative(relative_path),
         :ok <- ensure_scope(relative_path, scopes) do
      if File.exists?(addressed) do
        with {:ok, existing} <- resolve_existing(project, addressed, kind: :any, scopes: scopes) do
          {:ok, Map.put(existing, :exists?, true)}
        end
      else
        with {:ok, parent} <- existing_parent(addressed, root),
             {:ok, _parent_info} <- resolve_existing(project, parent, kind: :directory) do
          {:ok,
           %{
             path: addressed,
             relative_path: relative_path,
             canonical_path: addressed,
             canonical_relative_path: relative_path,
             type: :missing,
             size: 0,
             mtime: nil,
             exists?: false
           }}
        end
      end
    end
  end

  def read_text(info, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_text_file_bytes)

    with :ok <- ensure_regular_file(info),
         :ok <- ensure_file_size(info, max_bytes),
         {:ok, bytes} <- File.read(info.path),
         :ok <- ensure_text(bytes) do
      {:ok, bytes}
    end
  end

  def write_file(info, bytes) when is_binary(bytes) do
    with :ok <- ensure_write_size(bytes),
         :ok <- ensure_not_directory(info),
         :ok <- File.mkdir_p(Path.dirname(info.path)) do
      File.write(info.path, bytes)
    end
  end

  def sha256(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes)
    |> Base.encode16(case: :lower)
  end

  def list_entries(project, start_info, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)
    limit = Keyword.get(opts, :limit, 100)
    started_at = System.monotonic_time(:millisecond)
    timeout_ms = Keyword.get(opts, :timeout_ms, 2_000)

    do_list_entries(project, [start_info.path], recursive, limit, started_at, timeout_ms, [])
    |> case do
      {:ok, entries, truncated} ->
        {:ok, %{entries: Enum.reverse(entries), truncated: truncated}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def text_file_infos(project, start_info, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1_000)

    with {:ok, %{entries: entries, truncated: truncated}} <-
           list_entries(project, start_info,
             recursive: true,
             limit: limit,
             timeout_ms: Keyword.get(opts, :timeout_ms, 2_000)
           ) do
      files =
        entries
        |> Enum.filter(&(&1.type == :regular))
        |> Enum.filter(&safe_text_candidate?/1)

      {:ok, %{entries: files, truncated: truncated}}
    end
  end

  def entry_result(info) do
    %{
      "name" => Path.basename(info.path),
      "relative_path" => info.relative_path,
      "type" => type_name(info.type),
      "size" => info.size,
      "mtime" => mtime_iso(info.mtime)
    }
  end

  def glob_match?(relative_path, basename, pattern) when is_binary(pattern) do
    pattern = String.trim(pattern)

    cond do
      pattern == "" ->
        true

      String.contains?(pattern, ["*", "?", "[", "]"]) ->
        Regex.match?(glob_regex(pattern), relative_path) or
          Regex.match?(glob_regex(pattern), basename)

      String.contains?(pattern, "/") ->
        relative_path == pattern

      true ->
        String.contains?(String.downcase(basename), String.downcase(pattern))
    end
  end

  def glob_match?(_relative_path, _basename, _pattern), do: true

  def image_file?(path), do: Avcs.Assets.supported_image?(path)

  def upsert_image_if_supported(project, path, context, source) do
    if image_file?(path) do
      opts =
        [
          source: source,
          thread_id: value(context, :thread_id),
          turn_id: value(context, :turn_id)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case Avcs.Assets.upsert_asset(project, path, opts) do
        {:ok, asset} ->
          Avcs.Events.broadcast("asset:created", %{asset: asset})
          {:ok, asset}

        {:error, reason} ->
          {:error, error(:asset_upsert_failed, "Image asset could not be saved", inspect(reason))}
      end
    else
      {:ok, nil}
    end
  end

  def value(attrs, key) when is_map(attrs) and is_atom(key),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  def value(attrs, key) when is_map(attrs) and is_binary(key) do
    Map.get(attrs, key) ||
      Enum.find_value(attrs, fn
        {atom_key, value} when is_atom(atom_key) ->
          if Atom.to_string(atom_key) == key, do: value

        {_other_key, _value} ->
          nil
      end)
  end

  def value(attrs, key) when is_list(attrs), do: Keyword.get(attrs, key)
  def value(_attrs, _key), do: nil

  defp do_list_entries(_project, _dirs, _recursive, limit, _started_at, _timeout_ms, acc)
       when length(acc) >= limit do
    {:ok, acc, true}
  end

  defp do_list_entries(_project, [], _recursive, _limit, _started_at, _timeout_ms, acc) do
    {:ok, acc, false}
  end

  defp do_list_entries(project, [dir | rest], recursive, limit, started_at, timeout_ms, acc) do
    if System.monotonic_time(:millisecond) - started_at > timeout_ms do
      {:ok, acc, true}
    else
      with {:ok, names} <- File.ls(dir) do
        {next_dirs, acc, truncated} =
          Enum.reduce_while(Enum.sort(names), {[], acc, false}, fn name,
                                                                   {dirs, acc, _truncated} ->
            cond do
              System.monotonic_time(:millisecond) - started_at > timeout_ms ->
                {:halt, {dirs, acc, true}}

              length(acc) >= limit ->
                {:halt, {dirs, acc, true}}

              true ->
                child_path = Path.join(dir, name)

                case entry_info(project, child_path) do
                  {:ok, info} ->
                    dirs =
                      if recursive and info.type == :directory do
                        [info.path | dirs]
                      else
                        dirs
                      end

                    {:cont, {dirs, [info | acc], false}}

                  {:error, _reason} ->
                    {:cont, {dirs, acc, false}}
                end
            end
          end)

        if truncated do
          {:ok, acc, true}
        else
          do_list_entries(
            project,
            Enum.reverse(next_dirs) ++ rest,
            recursive,
            limit,
            started_at,
            timeout_ms,
            acc
          )
        end
      else
        {:error, reason} ->
          {:error, error(:list_failed, "Directory could not be listed", inspect(reason))}
      end
    end
  end

  defp entry_info(project, path) do
    with {:ok, root} <- project_root(project),
         addressed = Path.expand(path),
         :ok <- ensure_inside_project(addressed, root),
         {:ok, stat} <- lstat(addressed),
         {:ok, relative_path} <- project_relative_path(project, addressed),
         :ok <- ensure_safe_relative(relative_path),
         {:ok, canonical_path} <- canonical_existing_path(root, relative_path),
         canonical_relative_path = relative_path,
         :ok <- ensure_safe_relative(canonical_relative_path) do
      {:ok,
       %{
         path: addressed,
         canonical_path: canonical_path,
         relative_path: relative_path,
         canonical_relative_path: canonical_relative_path,
         type: stat.type,
         size: stat.size,
         mtime: stat.mtime
       }}
    end
  end

  defp project_root(nil),
    do: {:error, error(:project_required, "Current Avcs project is required")}

  defp project_root(project) do
    root = Avcs.Projects.folder_path(project)

    cond do
      not is_binary(root) or root == "" ->
        {:error, error(:project_required, "Current Avcs project is required")}

      not File.dir?(root) ->
        {:error, error(:project_required, "Current Avcs project folder is missing")}

      true ->
        {:ok, Path.expand(root)}
    end
  end

  defp addressed_path(_root, nil), do: {:error, error(:path_required, "Path is required")}
  defp addressed_path(_root, ""), do: {:error, error(:path_required, "Path is required")}
  defp addressed_path(root, path) when is_binary(path), do: {:ok, Path.expand(path, root)}
  defp addressed_path(_root, _path), do: {:error, error(:invalid_path, "Path is invalid")}

  defp ensure_inside_project(path, root) do
    if Avcs.Projects.inside?(path, root) do
      :ok
    else
      {:error, error(:outside_project, "Path is outside the current Avcs project")}
    end
  end

  defp project_relative_path(project, path) do
    case Avcs.Projects.relative_to_project(project, path) do
      {:ok, relative_path} ->
        {:ok, relative_path}

      {:error, :outside_project} ->
        {:error, error(:outside_project, "Path is outside the current Avcs project")}
    end
  end

  defp lstat(path) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} ->
        {:ok, stat}

      {:error, :enoent} ->
        {:error, error(:not_found, "Path was not found")}

      {:error, reason} ->
        {:error, error(:file_access_failed, "Path could not be inspected", inspect(reason))}
    end
  end

  defp canonical_existing_path(root, relative_path) do
    case ensure_no_symlink_components(root, relative_path) do
      :ok -> {:ok, project_path(root, relative_path)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_no_symlink_components(root, relative_path) do
    segments = if relative_path == ".", do: [], else: Path.split(relative_path)

    segments
    |> Enum.reduce_while(root, fn segment, current ->
      next = Path.join(current, segment)

      case File.lstat(next, time: :posix) do
        {:ok, %{type: :symlink}} ->
          {:halt,
           {:error, error(:symlink_denied, "Symlinks are not allowed for AvcsAgent tools")}}

        {:ok, _stat} ->
          {:cont, next}

        {:error, reason} ->
          {:halt,
           {:error, error(:file_access_failed, "Path could not be inspected", inspect(reason))}}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_path(root, "."), do: root
  defp project_path(root, relative_path), do: Path.join(root, relative_path)

  defp existing_parent(path, root) do
    parent = Path.dirname(path)

    cond do
      not Avcs.Projects.inside?(parent, root) ->
        {:error, error(:outside_project, "Path parent is outside the current Avcs project")}

      File.exists?(parent) ->
        {:ok, parent}

      parent == root ->
        {:ok, root}

      true ->
        existing_parent(parent, root)
    end
  end

  defp ensure_safe_relative("."), do: :ok

  defp ensure_safe_relative(relative_path) do
    segments = Path.split(relative_path)
    basename = Path.basename(relative_path)

    cond do
      ".avcs" in segments ->
        {:error, error(:path_denied, "Access to .avcs is not allowed")}

      sqlite_path?(basename) ->
        {:error,
         error(:path_denied, "SQLite database files are not accessible to AvcsAgent tools")}

      Regex.match?(@secret_name_pattern, basename) ->
        {:error, error(:path_denied, "Secret-like files are not accessible to AvcsAgent tools")}

      true ->
        :ok
    end
  end

  defp sqlite_path?(basename) do
    ext = basename |> String.downcase() |> Path.extname()

    ext in @denied_extensions or
      String.match?(String.downcase(basename), ~r/\.(sqlite3?|db)-(wal|shm)$/)
  end

  defp ensure_scope(_relative_path, [:project]), do: :ok

  defp ensure_scope(relative_path, scopes) when is_list(scopes) do
    if Enum.any?(scopes, &inside_scope?(relative_path, &1)) do
      :ok
    else
      {:error, error(:path_denied, "Path is outside the allowed tool scope")}
    end
  end

  defp ensure_scope(_relative_path, _scope),
    do: {:error, error(:path_denied, "Invalid tool scope")}

  defp inside_scope?(_relative_path, :project), do: true
  defp inside_scope?("work", :work), do: true
  defp inside_scope?("work/" <> _rest, :work), do: true
  defp inside_scope?("output", :output), do: true
  defp inside_scope?("output/" <> _rest, :output), do: true
  defp inside_scope?(_relative_path, _scope), do: false

  defp ensure_symlink_allowed(:symlink, true), do: :ok

  defp ensure_symlink_allowed(:symlink, false),
    do: {:error, error(:symlink_denied, "Symlinks are not allowed for this AvcsAgent tool")}

  defp ensure_symlink_allowed(_type, _allow_symlink), do: :ok

  defp ensure_kind(_type, :any), do: :ok
  defp ensure_kind(:regular, :file), do: :ok
  defp ensure_kind(:directory, :directory), do: :ok
  defp ensure_kind(:symlink, :symlink), do: :ok
  defp ensure_kind(_type, :file), do: {:error, error(:not_file, "Path is not a file")}

  defp ensure_kind(_type, :directory),
    do: {:error, error(:not_directory, "Path is not a directory")}

  defp ensure_kind(_type, _kind),
    do: {:error, error(:unsupported_file_type, "File type is unsupported")}

  defp ensure_regular_file(%{type: :regular}), do: :ok
  defp ensure_regular_file(_info), do: {:error, error(:not_file, "Path is not a regular file")}

  defp ensure_file_size(%{size: size}, max_bytes) when is_integer(size) and size <= max_bytes,
    do: :ok

  defp ensure_file_size(%{size: size}, max_bytes),
    do:
      {:error,
       error(:file_too_large, "File is too large for this AvcsAgent tool", %{
         "size" => size,
         "max_size" => max_bytes
       })}

  defp ensure_text(bytes) when is_binary(bytes) do
    cond do
      String.contains?(bytes, <<0>>) ->
        {:error, error(:binary_file, "Binary files are not readable by this AvcsAgent tool")}

      not String.valid?(bytes) ->
        {:error, error(:binary_file, "File is not valid UTF-8 text")}

      true ->
        :ok
    end
  end

  defp ensure_write_size(bytes) when byte_size(bytes) <= @max_write_bytes, do: :ok

  defp ensure_write_size(bytes),
    do:
      {:error,
       error(:content_too_large, "Content is too large for this AvcsAgent tool", %{
         "size" => byte_size(bytes),
         "max_size" => @max_write_bytes
       })}

  defp ensure_not_directory(%{type: :directory}),
    do: {:error, error(:is_directory, "Cannot write over a directory")}

  defp ensure_not_directory(_info), do: :ok

  defp safe_text_candidate?(%{size: size}) when size > @max_text_file_bytes, do: false

  defp safe_text_candidate?(%{path: path}) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, 4096) end) do
      {:ok, bytes} when is_binary(bytes) ->
        not String.contains?(bytes, <<0>>) and String.valid?(bytes)

      _result ->
        false
    end
  end

  defp parse_integer(value, _default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp glob_regex(pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> String.replace("\\?", "[^/]")
    |> then(&("^" <> &1 <> "$"))
    |> Regex.compile!()
  end

  defp type_name(:regular), do: "file"
  defp type_name(:directory), do: "directory"
  defp type_name(:symlink), do: "symlink"
  defp type_name(type), do: to_string(type)

  defp mtime_iso(nil), do: nil

  defp mtime_iso(mtime) when is_integer(mtime) do
    mtime
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end
end
