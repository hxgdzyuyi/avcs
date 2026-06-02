defmodule Avcs.Storage.SQLite do
  @moduledoc false

  alias Exqlite.Sqlite3

  def with_db(path, fun) when is_binary(path) and is_function(fun, 1) do
    File.mkdir_p!(Path.dirname(path))

    with {:ok, db} <- Sqlite3.open(path) do
      try do
        exec!(db, """
        PRAGMA foreign_keys = ON;
        PRAGMA busy_timeout = 5000;
        PRAGMA journal_mode = WAL;
        """)

        {:ok, fun.(db)}
      rescue
        exception ->
          {:error, Exception.message(exception)}
      after
        Sqlite3.close(db)
      end
    end
  end

  def with_db!(path, fun) do
    case with_db(path, fun) do
      {:ok, result} -> result
      {:error, reason} -> raise RuntimeError, message: inspect(reason)
    end
  end

  def exec!(db, sql) do
    case Sqlite3.execute(db, sql) do
      :ok -> :ok
      {:error, reason} -> raise RuntimeError, message: "sqlite exec failed: #{inspect(reason)}"
    end
  end

  def run!(db, sql, params \\ []) do
    with_statement(db, sql, params, fn statement ->
      case Sqlite3.step(db, statement) do
        :done -> :ok
        {:row, _row} -> :ok
        :busy -> raise RuntimeError, message: "sqlite database busy"
        {:error, reason} -> raise RuntimeError, message: "sqlite run failed: #{inspect(reason)}"
      end
    end)
  end

  def all!(db, sql, params \\ []) do
    with_statement(db, sql, params, fn statement ->
      {:ok, columns} = Sqlite3.columns(db, statement)
      {:ok, rows} = Sqlite3.fetch_all(db, statement)

      Enum.map(rows, fn row ->
        columns
        |> Enum.zip(row)
        |> Map.new()
      end)
    end)
  end

  def one!(db, sql, params \\ []) do
    db
    |> all!(sql, params)
    |> List.first()
  end

  def scalar!(db, sql, params \\ []) do
    case one!(db, sql, params) do
      nil ->
        nil

      row ->
        row
        |> Map.values()
        |> List.first()
    end
  end

  def transaction!(db, fun) when is_function(fun, 0) do
    exec!(db, "BEGIN IMMEDIATE")

    try do
      result = fun.()
      exec!(db, "COMMIT")
      result
    rescue
      exception ->
        exec!(db, "ROLLBACK")
        reraise exception, __STACKTRACE__
    end
  end

  defp with_statement(db, sql, params, fun) do
    case Sqlite3.prepare(db, sql) do
      {:ok, statement} ->
        try do
          :ok = Sqlite3.bind(statement, params)
          fun.(statement)
        after
          Sqlite3.release(db, statement)
        end

      {:error, reason} ->
        raise RuntimeError, message: "sqlite prepare failed: #{inspect(reason)}"
    end
  end
end
