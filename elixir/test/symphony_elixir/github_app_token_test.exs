defmodule SymphonyElixir.GitHubAppTokenTest do
  # `async: false` because the module under test caches the live token in `:persistent_term`, which
  # belongs to the VM rather than to a test process.
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHubAppToken

  @api_url "https://api.github.test"
  @app_id 5_133_908
  # A fixed clock and a token that dies an hour later, so expiration is arithmetic in the test
  # rather than a race against the wall clock.
  @now 1_700_000_000
  @expires_at @now + 3_600
  @installation_id 42
  @login "lhl20"
  @installations [%{"id" => @installation_id, "account" => %{"login" => @login}}]

  setup_all do
    key = :public_key.generate_key({:rsa, 2048, 65_537})

    File.write!(pkcs8_key_path(), pkcs8_pem(key))
    File.write!(pkcs1_key_path(), pkcs1_pem(key))
    File.write!(broken_key_path(), broken_key_pem())
    File.write!(not_pem_path(), "this file is not a PEM block at all")

    on_exit(fn ->
      Enum.each([pkcs8_key_path(), pkcs1_key_path(), broken_key_path(), not_pem_path()], &File.rm/1)
    end)

    {:ok, public_key: {:RSAPublicKey, elem(key, 2), elem(key, 3)}}
  end

  setup do
    GitHubAppToken.reset_cache()
    :ok
  end

  describe "minting" do
    test "exchanges a signed JWT for the installation's token, with its expiry" do
      {client, _agent} = start_client([installations_response(@installations), token_response("ghs_stubbed")])

      assert {:ok, token} = GitHubAppToken.installation_token(opts(client))
      assert token.token == "ghs_stubbed"
      assert token.expires_at == DateTime.from_unix!(@expires_at)
      assert token.installation_id == @installation_id
      assert token.app_id == @app_id
    end

    test "the JWT is RS256 with iat in the past and exp under GitHub's ten-minute cap" do
      {client, agent} = start_client([installations_response(@installations), token_response("ghs_stubbed")])

      assert {:ok, _token} = GitHubAppToken.installation_token(opts(client))

      jwt = agent |> requests() |> hd() |> bearer()
      [header_segment, claims_segment, _signature_segment] = String.split(jwt, ".")

      assert decode_segment(header_segment) == %{"alg" => "RS256", "typ" => "JWT"}
      assert decode_segment(claims_segment) == %{"iss" => @app_id, "iat" => @now - 60, "exp" => @now + 540}
    end

    test "the signature verifies against the App's public key", %{public_key: public_key} do
      {client, agent} = start_client([installations_response(@installations), token_response("ghs_stubbed")])

      assert {:ok, _token} = GitHubAppToken.installation_token(opts(client))

      jwt = agent |> requests() |> hd() |> bearer()
      [header_segment, claims_segment, signature_segment] = String.split(jwt, ".")

      signing_input = header_segment <> "." <> claims_segment
      signature = Base.url_decode64!(signature_segment, padding: false)

      assert :public_key.verify(signing_input, :sha256, signature, public_key)
    end

    test "asks the App API for installations, then posts to that installation's access_tokens" do
      {client, agent} = start_client([installations_response(@installations), token_response("ghs_stubbed")])

      assert {:ok, _token} = GitHubAppToken.installation_token(opts(client))

      [discovery, mint] = requests(agent)

      assert discovery[:method] == :get
      assert discovery[:url] == @api_url <> "/app/installations"
      refute Keyword.has_key?(discovery, :json)

      assert mint[:method] == :post
      assert mint[:url] == @api_url <> "/app/installations/#{@installation_id}/access_tokens"
      assert mint[:json] == %{}

      # Both requests authenticate with the same JWT: it is minted once per token, not per request.
      assert bearer(discovery) == bearer(mint)
    end

    test "the requests carry GitHub's required headers" do
      {client, agent} = start_client([installations_response(@installations), token_response("ghs_stubbed")])

      assert {:ok, _token} = GitHubAppToken.installation_token(opts(client))

      headers = hd(requests(agent))[:headers]

      assert {"Accept", "application/vnd.github+json"} in headers
      assert {"X-GitHub-Api-Version", "2022-11-28"} in headers
      assert {"User-Agent", "symphony"} in headers

      assert Enum.any?(headers, fn {name, value} ->
               name == "Authorization" and String.starts_with?(value, "Bearer ")
             end)
    end

    test "no retries and a bounded timeout, so a dead API answers in seconds" do
      {client, agent} = start_client([installations_response(@installations), token_response("ghs_stubbed")])

      assert {:ok, _token} = GitHubAppToken.installation_token(opts(client))

      req_opts = hd(requests(agent))
      assert req_opts[:retry] == false
      assert req_opts[:receive_timeout] == 15_000
      assert req_opts[:connect_options] == [timeout: 15_000]
    end

    test "picks the installation whose account matches :account, case-insensitively" do
      others = [
        %{"id" => 1, "account" => %{"login" => "acme"}},
        %{"id" => @installation_id, "account" => %{"login" => "LHL20"}}
      ]

      {client, agent} = start_client([installations_response(others), token_response("ghs_stubbed")])

      assert {:ok, %{installation_id: @installation_id}} =
               GitHubAppToken.installation_token(opts(client, account: @login))

      assert Enum.at(requests(agent), 1)[:url] ==
               @api_url <> "/app/installations/#{@installation_id}/access_tokens"
    end

    test "an explicit installation_id skips discovery entirely" do
      {client, agent} = start_client([token_response("ghs_stubbed")])

      assert {:ok, %{installation_id: 7}} = GitHubAppToken.installation_token(opts(client, installation_id: 7))

      assert [request] = requests(agent)
      assert request[:method] == :post
      assert request[:url] == @api_url <> "/app/installations/7/access_tokens"
    end

    test "accepts a numeric string app id, which is what a YAML or env setting looks like" do
      {client, _agent} = start_client([installations_response(@installations), token_response("ghs_stubbed")])

      assert {:ok, %{app_id: @app_id}} = GitHubAppToken.installation_token(opts(client, app_id: "5133908"))
    end

    test "accepts a PKCS#1 (RSA PRIVATE KEY) export as well as PKCS#8" do
      {client, _agent} = start_client([installations_response(@installations), token_response("ghs_stubbed")])

      assert {:ok, %{token: "ghs_stubbed"}} =
               GitHubAppToken.installation_token(opts(client, private_key_path: pkcs1_key_path()))
    end

    test "a custom api_url is used verbatim, minus a trailing slash" do
      {client, agent} = start_client([installations_response(@installations), token_response("ghs_stubbed")])

      assert {:ok, _token} =
               GitHubAppToken.installation_token(opts(client, api_url: "https://ghe.example/api/v3/"))

      assert hd(requests(agent))[:url] == "https://ghe.example/api/v3/app/installations"
    end
  end

  describe "caching" do
    test "reuses the token while it has more than the refresh slack left" do
      {client, agent} =
        start_client([
          installations_response(@installations),
          token_response("ghs_first")
        ])

      assert {:ok, %{token: "ghs_first"}} = GitHubAppToken.installation_token(opts(client))
      # A second stubbed response would have to exist for a re-mint to succeed, so getting the same
      # token back proves the second call never went to the network.
      assert {:ok, %{token: "ghs_first"}} = GitHubAppToken.installation_token(opts(client))
      assert length(requests(agent)) == 2
    end

    test "re-mints once the slack is gone, and not one second earlier" do
      {now_fun, set_now} = clock(@now)

      {client, agent} =
        start_client([
          installations_response(@installations),
          token_response("ghs_first"),
          installations_response(@installations),
          token_response("ghs_second")
        ])

      call = fn -> GitHubAppToken.installation_token(opts(client, now_fun: now_fun)) end

      assert {:ok, %{token: "ghs_first"}} = call.()

      # The slack is 300 seconds: 301 seconds left is still usable, 300 is not.
      set_now.(@expires_at - 301)
      assert {:ok, %{token: "ghs_first"}} = call.()
      assert length(requests(agent)) == 2

      set_now.(@expires_at - 300)
      assert {:ok, %{token: "ghs_second"}} = call.()
      assert length(requests(agent)) == 4
    end

    test "an already-expired cached token is not handed out" do
      {now_fun, set_now} = clock(@now)

      {client, _agent} =
        start_client([
          installations_response(@installations),
          token_response("ghs_first"),
          installations_response(@installations),
          token_response("ghs_second")
        ])

      assert {:ok, %{token: "ghs_first"}} = GitHubAppToken.installation_token(opts(client, now_fun: now_fun))

      set_now.(@expires_at + 1)
      assert {:ok, %{token: "ghs_second"}} = GitHubAppToken.installation_token(opts(client, now_fun: now_fun))
    end

    test "a cached token minted for one App is not handed to a call for another" do
      {client, _agent} =
        start_client([
          installations_response(@installations),
          token_response("ghs_app_a"),
          installations_response(@installations),
          token_response("ghs_app_b")
        ])

      assert {:ok, %{token: "ghs_app_a", app_id: @app_id}} = GitHubAppToken.installation_token(opts(client))

      assert {:ok, %{token: "ghs_app_b", app_id: 999}} =
               GitHubAppToken.installation_token(opts(client, app_id: 999))
    end

    test "reset_cache/0 throws the token away so a revoked one is not reused" do
      {client, _agent} =
        start_client([
          installations_response(@installations),
          token_response("ghs_first"),
          installations_response(@installations),
          token_response("ghs_second")
        ])

      assert {:ok, %{token: "ghs_first"}} = GitHubAppToken.installation_token(opts(client))
      assert :ok = GitHubAppToken.reset_cache()
      assert {:ok, %{token: "ghs_second"}} = GitHubAppToken.installation_token(opts(client))
    end
  end

  describe "failures" do
    test "a missing app id is reported, not defaulted" do
      {client, agent} = start_client([])

      assert {:error, {:missing_option, :app_id}} =
               GitHubAppToken.installation_token(opts(client, app_id: nil))

      assert requests(agent) == []
    end

    test "a missing key path is reported, not defaulted" do
      {client, agent} = start_client([])

      assert {:error, {:missing_option, :private_key_path}} =
               GitHubAppToken.installation_token(opts(client, private_key_path: nil))

      assert requests(agent) == []
    end

    test "an unreadable key names the path and the reason" do
      {client, agent} = start_client([])
      missing = pkcs8_key_path() <> ".missing"

      assert {:error, {:key_unreadable, ^missing, :enoent}} =
               GitHubAppToken.installation_token(opts(client, private_key_path: missing))

      assert requests(agent) == []
    end

    test "a file that holds no PEM block is reported as undecodable" do
      {client, agent} = start_client([])

      assert {:error, {:key_undecodable, _path, :no_rsa_private_key_entry}} =
               GitHubAppToken.installation_token(opts(client, private_key_path: not_pem_path()))

      assert requests(agent) == []
    end

    test "a key that cannot sign fails as signing_failed, before any request" do
      {client, agent} = start_client([])

      assert {:error, {:signing_failed, message}} =
               GitHubAppToken.installation_token(opts(client, private_key_path: broken_key_path()))

      assert is_binary(message)
      assert requests(agent) == []
    end

    test "an unreachable API is reported with the transport reason" do
      {client, _agent} = start_client([{:error, :econnrefused}])

      assert {:error, {:api_unreachable, :econnrefused}} = GitHubAppToken.installation_token(opts(client))
    end

    test "a non-2xx carries GitHub's own message, which is the part that explains why" do
      body = %{"message" => "A JSON web token could not be decoded", "documentation_url" => "https://docs"}
      {client, _agent} = start_client([{:ok, %{status: 401, body: body}}])

      assert {:error, {:api_status, 401, "A JSON web token could not be decoded"}} =
               GitHubAppToken.installation_token(opts(client))
    end

    test "a non-JSON error body is still shown as text rather than swallowed" do
      {client, _agent} = start_client([{:ok, %{status: 502, body: "<html>bad gateway</html>"}}])

      assert {:error, {:api_status, 502, message}} = GitHubAppToken.installation_token(opts(client))
      assert message =~ "bad gateway"
    end

    test "an App that is installed nowhere is missing_installation" do
      {client, _agent} = start_client([installations_response([])])

      assert {:error, :missing_installation} = GitHubAppToken.installation_token(opts(client))
    end

    test "an account that matches no installation lists the ones that exist" do
      others = [
        %{"id" => 1, "account" => %{"login" => "acme"}},
        %{"id" => 2, "account" => %{"login" => @login}}
      ]

      {client, _agent} = start_client([installations_response(others)])

      assert {:error, {:installation_not_found, "someone-else", ["acme", @login]}} =
               GitHubAppToken.installation_token(opts(client, account: "someone-else"))
    end

    test "several installations with no account to choose between them is ambiguous, not a guess" do
      others = [
        %{"id" => 1, "account" => %{"login" => "acme"}},
        %{"id" => 2, "account" => %{"login" => @login}},
        %{"id" => 3}
      ]

      {client, _agent} = start_client([installations_response(others)])

      assert {:error, {:ambiguous_installation, ["acme", @login]}} = GitHubAppToken.installation_token(opts(client))
    end

    test "an installations response that is not a JSON array is malformed" do
      {client, _agent} = start_client([{:ok, %{status: 200, body: %{"installations" => []}}}])

      assert {:error, {:malformed_response, detail}} = GitHubAppToken.installation_token(opts(client))
      assert detail =~ "JSON array"
    end

    test "a token response with no token is malformed" do
      body = %{"expires_at" => iso(@expires_at)}
      {client, _agent} = start_client([installations_response(@installations), {:ok, %{status: 201, body: body}}])

      assert {:error, {:malformed_response, detail}} = GitHubAppToken.installation_token(opts(client))
      assert detail =~ "no token"
    end

    test "a token response with no usable expires_at is malformed" do
      body = %{"token" => "ghs_stubbed", "expires_at" => "the day after tomorrow"}
      {client, _agent} = start_client([installations_response(@installations), {:ok, %{status: 201, body: body}}])

      assert {:error, {:malformed_response, detail}} = GitHubAppToken.installation_token(opts(client))
      assert detail =~ "expires_at"
    end

    test "a 200 whose body is not JSON at all is malformed, not a crash" do
      {client, _agent} =
        start_client([installations_response(@installations), {:ok, %{status: 200, body: "<html>hi</html>"}}])

      assert {:error, {:malformed_response, _detail}} = GitHubAppToken.installation_token(opts(client))
    end

    test "a client that returns something unexplainable is reported, not pattern-matched to death" do
      {client, _agent} = start_client([:nothing_like_a_response])

      assert {:error, {:api_unreachable, {:unexpected_request_fun_return, :nothing_like_a_response}}} =
               GitHubAppToken.installation_token(opts(client))
    end

    test "a bogus clock is a bug, reported as unexpected rather than raised" do
      {client, agent} = start_client([])

      assert {:error, {:unexpected, message}} =
               GitHubAppToken.installation_token(opts(client, now_fun: fn -> :not_a_time end))

      assert is_binary(message)
      assert requests(agent) == []
    end

    test "opts that are not a keyword list are reported rather than raising a FunctionClauseError" do
      assert {:error, {:invalid_option, :opts, :nope}} = GitHubAppToken.installation_token(:nope)
    end
  end

  # -- helpers ---------------------------------------------------------------------------------

  # `Keyword.merge/2` and not `++`: a test that overrides `:app_id` or `:now_fun` has to win over
  # the default, and `Keyword.get/3` reads the first occurrence.
  defp opts(client, extra \\ []) do
    Keyword.merge(
      [
        app_id: @app_id,
        private_key_path: pkcs8_key_path(),
        api_url: @api_url,
        request_fun: client,
        now_fun: fn -> @now end
      ],
      extra
    )
  end

  # A stub HTTP client: hands back the next stubbed response and records the request options, so a
  # test can assert on the paths, headers and JWT that really went out -- and can prove that a
  # cached call sent nothing at all. Nothing here touches the network.
  defp start_client(responses) do
    {:ok, agent} = Agent.start_link(fn -> %{responses: responses, requests: []} end)

    client = fn req_opts ->
      Agent.get_and_update(agent, fn state ->
        {response, rest} = pop_response(state.responses, req_opts)
        {response, %{state | responses: rest, requests: state.requests ++ [req_opts]}}
      end)
    end

    {client, agent}
  end

  # Running out of stubs is a failure the test can still read, rather than a crash inside the client.
  defp pop_response([response | rest], _req_opts), do: {response, rest}
  defp pop_response([], req_opts), do: {{:error, {:no_stubbed_response, req_opts[:method]}}, []}

  defp requests(agent), do: Agent.get(agent, & &1.requests)

  defp bearer(req_opts) do
    {_name, value} = Enum.find(req_opts[:headers], fn {name, _value} -> name == "Authorization" end)
    String.replace_prefix(value, "Bearer ", "")
  end

  defp decode_segment(segment), do: segment |> Base.url_decode64!(padding: false) |> Jason.decode!()

  defp installations_response(list), do: {:ok, %{status: 200, body: list}}

  defp token_response(token, expires_at \\ @expires_at) do
    {:ok, %{status: 201, body: %{"token" => token, "expires_at" => iso(expires_at)}}}
  end

  defp iso(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp clock(seconds) do
    {:ok, agent} = Agent.start_link(fn -> seconds end)
    {fn -> Agent.get(agent, & &1) end, fn next -> Agent.update(agent, fn _current -> next end) end}
  end

  # Throwaway RSA keys for one run, under the OS temp directory and deleted on exit. They are
  # generated by the test and never leave this machine; the App's real key is not involved and is
  # not copied into the repository.
  defp pkcs8_key_path, do: key_path("pkcs8")
  defp pkcs1_key_path, do: key_path("pkcs1")
  defp broken_key_path, do: key_path("broken")
  defp not_pem_path, do: key_path("notpem")

  defp key_path(kind) do
    Path.join(System.tmp_dir!(), "symphony-gh-app-token-#{kind}-#{:os.getpid()}.pem")
  end

  # An RSA key in PKCS#8 ("PRIVATE KEY"), which is what the module has to read.
  defp pkcs8_pem(key), do: :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])

  # The same key in PKCS#1 ("RSA PRIVATE KEY") -- the export GitHub hands out.
  defp pkcs1_pem(key), do: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

  # A DER-valid PKCS#1 record whose numbers are nonsense: it decodes -- so the module gets past
  # reading the key -- and only `:public_key.sign/3` refuses it. That is the signing failure, and
  # without a key like this the branch would be unreachable from a test.
  defp broken_key_pem do
    record = {:RSAPrivateKey, 0, 0, 65_537, 1, 3, 5, 7, 11, 13, :asn1_NOVALUE}
    der = :public_key.der_encode(:RSAPrivateKey, record)
    :public_key.pem_encode([{:RSAPrivateKey, der, :not_encrypted}])
  end
end
