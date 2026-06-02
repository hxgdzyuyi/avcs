defmodule Avcs.Time do
  @moduledoc false

  def now_iso do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
