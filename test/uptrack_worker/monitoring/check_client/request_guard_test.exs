defmodule UptrackWorker.Monitoring.CheckClient.RequestGuardTest do
  use ExUnit.Case, async: true

  alias UptrackWorker.Monitoring.CheckClient.Gun
  alias UptrackWorker.Monitoring.CheckClient.RequestGuard
  alias UptrackWorker.Monitoring.GunConnection

  defp monitor(attrs \\ %{}) do
    Map.merge(
      %{id: "mon-1", url: "https://example.com/health?x=1", timeout: 5, settings: %{}},
      attrs
    )
  end

  defp with_settings(settings), do: monitor(%{settings: settings})

  describe "valid input passes unchanged" do
    test "default request" do
      request = Gun.build_request(monitor())
      assert request.method == :get
      assert request.path == "/health?x=1"
      assert RequestGuard.validate(request) == :ok
    end

    test "custom headers are kept and accepted" do
      m =
        with_settings(%{"headers" => %{"X-Api-Key" => "abc 123", "Authorization" => "Bearer t"}})

      request = Gun.build_request(m)

      assert {"X-Api-Key", "abc 123"} in request.headers
      assert {"Authorization", "Bearer t"} in request.headers
      assert {"user-agent", "Uptrack Monitor/1.0"} in request.headers
      assert RequestGuard.validate(request) == :ok
    end

    test "all allowlisted methods, any case" do
      for m <- ~w(get HEAD Post put patch DELETE options) do
        request = Gun.build_request(with_settings(%{"method" => m}))
        assert request.method == String.to_existing_atom(String.downcase(m))
        assert RequestGuard.validate(request) == :ok
      end
    end
  end

  describe "CR, LF and NUL are rejected" do
    for {label, char} <- [cr: "\r", lf: "\n", nul: <<0>>] do
      test "#{label} in a header value" do
        m = with_settings(%{"headers" => %{"X-Test" => "a#{unquote(char)}b: c"}})

        assert RequestGuard.validate(Gun.build_request(m)) ==
                 {:error, "invalid request: header value contains CR/LF/NUL"}
      end

      test "#{label} in a header name" do
        m = with_settings(%{"headers" => %{"X-Te#{unquote(char)}st" => "v"}})

        assert RequestGuard.validate(Gun.build_request(m)) ==
                 {:error, "invalid request: header name contains CR/LF/NUL"}
      end

      test "#{label} in the path" do
        m = monitor(%{url: "https://example.com/a#{unquote(char)}b"})

        assert RequestGuard.validate(Gun.build_request(m)) ==
                 {:error, "invalid request: path contains CR/LF/NUL"}
      end

      test "#{label} in the query" do
        request = %{method: :get, path: "/a?x=1#{unquote(char)}y=2", headers: []}

        assert RequestGuard.validate(request) ==
                 {:error, "invalid request: path contains CR/LF/NUL"}
      end
    end

    test "a CRLF injection through the real URL parser is rejected" do
      m = monitor(%{url: "https://example.com/ok\r\nHost: evil.example\r\n\r\n"})
      assert {:error, _} = RequestGuard.validate(Gun.build_request(m))
    end

    test "message does not echo the offending value" do
      m = with_settings(%{"headers" => %{"X-Test" => "secret-token\r\nInjected: 1"}})
      {:error, msg} = RequestGuard.validate(Gun.build_request(m))
      refute msg =~ "secret-token"
      refute msg =~ "Injected"
      refute msg =~ "\r"
      refute msg =~ "\n"
    end
  end

  describe "method" do
    test "unknown method is rejected and creates no atom" do
      name = "zz_not_a_method_#{System.unique_integer([:positive])}"
      request = Gun.build_request(with_settings(%{"method" => name}))

      assert RequestGuard.validate(request) ==
               {:error, "invalid request: unsupported HTTP method"}

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "CONNECT/TRACE and non-string methods are rejected" do
      for bad <- ["CONNECT", "TRACE", "GET\r\nX: y", "", 5, nil] do
        request = Gun.build_request(with_settings(%{"method" => bad}))
        assert {:error, _} = RequestGuard.validate(request)
      end
    end
  end

  test "non-string header name or value is rejected" do
    request = %{method: :get, path: "/", headers: [{"x-n", 5}]}

    assert RequestGuard.validate(request) ==
             {:error, "invalid request: header name or value is not a string"}
  end

  describe "Gun.check/2 failure result shape" do
    test "returns a down result, without a connection attempt" do
      m = with_settings(%{"headers" => %{"X-Test" => "a\r\nb"}})
      # pid is the test process itself: any :gun call on it would fail or hang
      conn = %GunConnection{pid: self(), host: "example.com", port: 443, tls?: true}

      result = Gun.check(m, conn)

      assert %{
               monitor_id: "mon-1",
               status: "down",
               response_time: 0,
               error_message: "invalid request: header value contains CR/LF/NUL",
               checked_at: %DateTime{}
             } = result

      refute Map.has_key?(result, :status_code)
    end

    test "bad method gives the same shape" do
      conn = %GunConnection{pid: self()}
      result = Gun.check(with_settings(%{"method" => "BREW"}), conn)
      assert result.status == "down"
      assert result.error_message == "invalid request: unsupported HTTP method"
    end
  end
end
