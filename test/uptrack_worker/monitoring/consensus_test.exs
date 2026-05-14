defmodule UptrackWorker.Monitoring.ConsensusTest do
  use ExUnit.Case, async: true

  alias UptrackWorker.Monitoring.Consensus

  test "majority up = up" do
    c =
      %Consensus{}
      |> Consensus.add_result(:eu, %{status: "up"})
      |> Consensus.add_result(:asia, %{status: "down"})
      |> Consensus.add_result(:us, %{status: "up"})

    assert Consensus.enough_results?(c)
    assert Consensus.compute(c) == "up"
  end

  test "majority down = down" do
    c =
      %Consensus{}
      |> Consensus.add_result(:eu, %{status: "down"})
      |> Consensus.add_result(:asia, %{status: "down"})
      |> Consensus.add_result(:us, %{status: "up"})

    assert Consensus.compute(c) == "down"
  end

  test "timeout with 2 results triggers partial consensus" do
    c =
      %Consensus{expected_regions: 3}
      |> Consensus.add_result(:eu, %{status: "up"})
      |> Consensus.add_result(:us, %{status: "up"})

    refute Consensus.enough_results?(c)

    c = Consensus.timeout(c)
    assert Consensus.enough_results?(c)
    assert Consensus.compute(c) == "up"
  end

  test "reset clears state" do
    c =
      %Consensus{}
      |> Consensus.add_result(:eu, %{status: "up"})
      |> Consensus.reset()

    assert c.region_results == %{}
    assert c.status == :waiting
  end

  test "home_node? is deterministic" do
    nodes = [:a@host, :b@host, :c@host]
    assert Consensus.home_node?("m1", nodes) == Consensus.home_node?("m1", nodes)
  end

  test "timeout with 1 result resolves (partial-region fallback)" do
    c =
      %Consensus{expected_regions: 3}
      |> Consensus.add_result(:eu, %{status: "up"})
      |> Consensus.timeout()

    assert Consensus.enough_results?(c)
  end

  test "timeout with zero results does not resolve" do
    c = %Consensus{expected_regions: 3} |> Consensus.timeout()
    refute Consensus.enough_results?(c)
  end

  describe "set_expected_regions/2" do
    test "updates the field" do
      c = Consensus.set_expected_regions(%Consensus{expected_regions: 1}, 5)
      assert c.expected_regions == 5
    end

    test "raises on non-integer or zero" do
      assert_raise FunctionClauseError, fn ->
        Consensus.set_expected_regions(%Consensus{}, "3")
      end

      assert_raise FunctionClauseError, fn ->
        Consensus.set_expected_regions(%Consensus{}, 0)
      end
    end
  end
end
