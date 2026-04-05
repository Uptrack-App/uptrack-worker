defmodule UptrackWorker.Monitoring.Consensus do
  @moduledoc """
  Pure consensus logic for multi-region check results.

  Identical to Uptrack.Monitoring.Consensus in the main app.
  No side effects, no DB, no messaging.
  """

  defstruct region_results: %{},
            expected_regions: 3,
            timer: nil,
            status: :waiting

  @type t :: %__MODULE__{
          region_results: %{atom() => map()},
          expected_regions: pos_integer(),
          timer: reference() | nil,
          status: :waiting | :ready | :timeout
        }

  @spec add_result(t(), atom(), map()) :: t()
  def add_result(%__MODULE__{} = c, region, result) do
    %{c | region_results: Map.put(c.region_results, region, result)}
  end

  @spec enough_results?(t()) :: boolean()
  def enough_results?(%__MODULE__{} = c) do
    received = map_size(c.region_results)
    received >= c.expected_regions or (received >= 2 and c.status == :timeout)
  end

  @spec compute(t()) :: String.t() | nil
  def compute(%__MODULE__{region_results: results}) when map_size(results) == 0, do: nil

  def compute(%__MODULE__{region_results: results}) do
    total = map_size(results)
    down_count = Enum.count(results, fn {_region, r} -> r.status == "down" end)
    if down_count > total / 2, do: "down", else: "up"
  end

  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = c) do
    %{c | region_results: %{}, status: :waiting, timer: nil}
  end

  @spec timeout(t()) :: t()
  def timeout(%__MODULE__{} = c), do: %{c | status: :timeout}

  @spec result_count(t()) :: non_neg_integer()
  def result_count(%__MODULE__{region_results: r}), do: map_size(r)

  @spec home_node?(String.t(), [node()]) :: boolean()
  def home_node?(monitor_id, sorted_nodes) do
    node_count = length(sorted_nodes)

    if node_count == 0 do
      true
    else
      hash = :erlang.phash2(monitor_id, node_count)
      Enum.at(sorted_nodes, hash) == node()
    end
  end
end
