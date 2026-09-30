defmodule SymphonyElixir.GitHubAppToken do
  @moduledoc """
  Mints GitHub App installation tokens (`ghs_...`) from an App's private key.

  A long-lived personal access token is the wrong credential for an agent that only has to push a
  branch and open a pull request: it never expires, it belongs to a person, and it is not scoped to
  one installation. An App installation token is the same authority with a one-hour life and no
  human behind it.

  The whole flow lives here:

    1. Read the App's private key from a PEM file (`:private_key_path`), decode it with
       `:public_key.pem_decode/1`, and sign a short-lived RS256 JWT with `:public_key.sign/3`
       (`iss` = the App id, `iat` = now - 60s, `exp` = now + 540s). No `openssl`, no `gh`.
    2. Find the installation: `GET /app/installations`, unless `:installation_id` is given.
    3. Exchange the JWT for a token: `POST /app/installations/:id/access_tokens`.

  ## Caching

  The live token is held in `:persistent_term`, not in an `Agent` or a `GenServer`, and that is a
  choice about ownership rather than taste. Minting happens once per hour and reading happens from
  whatever process is about to push, which is exactly the write-once/read-many shape
  `:persistent_term` exists for: a read takes no lock and copies nothing into the caller. A GenServer
  or a named `Agent` would need a place in the supervision tree to be more than a leak, and nothing
  supervises this module yet -- wiring it into the application is a later slice, and this cache does
  not depend on that slice happening. Writes cost a global scan, and there is at most one per hour.

  One App per VM: the cached entry carries its `app_id`, so a call for a different App is answered
  by minting rather than by the wrong App's token.

  ## Failures

  Every failure is a value shaped for a person to read, and the public entry point never raises:

    * `{:missing_option, :app_id | :private_key_path}` / `{:invalid_option, key, value}`
    * `{:key_unreadable, path, reason}` -- `File.read/1`'s reason, e.g. `:enoent`
    * `{:key_undecodable, path, reason}` -- not a PEM, or it carries no RSA private key
    * `{:signing_failed, reason}` -- `:public_key.sign/3` refused the key
    * `{:api_unreachable, reason}` -- transport failure; GitHub was never reached
    * `{:api_status, status, message}` -- GitHub answered with an error; `message` is its `message`
      field verbatim ("A JSON web token could not be decoded"), which is the part that explains why
    * `{:malformed_response, detail}` -- a 2xx that is not the documented shape
    * `:missing_installation` -- the App is not installed anywhere
    * `{:installation_not_found, account, logins}` -- `:account` matched none of the installations
    * `{:ambiguous_installation, logins}` -- several installations and no `:account` to choose
    * `{:unexpected, message}` -- a bug rather than a condition; the catch-all that keeps the entry
      point non-raising

  ## Options

    * `:private_key_path` (required) -- PEM file with the App's RSA private key, PKCS#1
      (`RSA PRIVATE KEY`) or PKCS#8 (`PRIVATE KEY`)
    * `:app_id` (required) -- the App id, integer or numeric string
    * `:installation_id` -- skip discovery
    * `:account` -- account login to pick when the App has more than one installation
    * `:api_url` -- defaults to `https://api.github.com`
    * `:request_fun` -- the injection point for the HTTP client, arity 1:
      `(keyword() -> {:ok, %{status: integer(), body: term()}} | {:error, term()})`, defaulting to
      `Req`
    * `:now_fun` -- the injection point for the clock, arity 0, returning unix seconds
  """

  @default_api_url "https://api.github.com"
  @api_version "2022-11-28"
  @user_agent "symphony"

  # GitHub rejects a JWT whose `iat` is in the future, and this machine's clock is not GitHub's, so
  # the credential's life starts a minute in the past; `exp` stays under GitHub's ten-minute cap.
  @iat_backdate_seconds 60
  @jwt_lifetime_seconds 540

  # An installation token lives an hour. Refresh with this much left, so a push that starts on the
  # last few minutes of a token cannot have the credential die mid-request.
  @refresh_slack_seconds 300

  @jwt_header %{"alg" => "RS256", "typ" => "JWT"}

  # `retry: false` on purpose: an API that is down should say so in seconds instead of after Req's
  # backoff -- the same reasoning as `RecorderClient`, where retrying turned a fast failure into a
  # 15-second one. `decode_body: false` because a body that is not JSON is precisely the
  # `{:malformed_response, _}` this module has to report, and Req would raise on it instead.
  @req_opts [receive_timeout: 15_000, connect_options: [timeout: 15_000], retry: false, decode_body: false]

  @cache_key {__MODULE__, :installation_token}

  @type token :: %{
          token: String.t(),
          expires_at: DateTime.t(),
          installation_id: integer(),
          app_id: integer()
        }

  @type error ::
          {:missing_option, atom()}
          | {:invalid_option, atom(), term()}
          | {:key_unreadable, Path.t(), term()}
          | {:key_undecodable, Path.t(), term()}
          | {:signing_failed, term()}
          | {:api_unreachable, term()}
          | {:api_status, integer(), String.t()}
          | {:malformed_response, String.t()}
          | :missing_installation
          | {:installation_not_found, String.t(), [String.t()]}
          | {:ambiguous_installation, [String.t()]}
          | {:unexpected, String.t()}

  @doc """
  Returns an installation token and when it dies, minting one only when the cached one is gone or
  within the refresh slack of dying.

  The token itself is the credential to hand to a coding agent; `expires_at` is there so the caller
  can tell whether a token it is about to use is still worth using. See the module doc for the
  failure shapes.
  """
  @spec installation_token(keyword()) :: {:ok, token()} | {:error, error()}
  def installation_token(opts) when is_list(opts) do
    with {:ok, app_id} <- app_id(opts) do
      mint_or_cached(app_id, opts)
    end
  rescue
    error -> {:error, {:unexpected, Exception.message(error)}}
  end

  # `opts` is not a keyword list. A guard clause would make this a FunctionClauseError, which is a
  # raise out of the public entry point; the promise is that there is none.
  def installation_token(other), do: {:error, {:invalid_option, :opts, other}}

  @doc """
  Drops the cached token so the next call mints a fresh one.

  For tests, and for an operator who has revoked a token and does not want to wait out the hour: a
  revoked token is otherwise indistinguishable from a live one until GitHub rejects it.
  """
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp mint_or_cached(app_id, opts) do
    now = now_fun(opts).()

    case cached_token(app_id, now) do
      {:ok, token} -> {:ok, token}
      :miss -> mint(app_id, opts, now)
    end
  end

  defp cached_token(app_id, now) do
    case :persistent_term.get(@cache_key, nil) do
      %{app_id: ^app_id, expires_at: %DateTime{} = expires_at} = entry ->
        fresh_entry(entry, expires_at, now)

      _other ->
        :miss
    end
  end

  defp fresh_entry(entry, expires_at, now) do
    if DateTime.to_unix(expires_at) - now > @refresh_slack_seconds do
      {:ok, entry}
    else
      :miss
    end
  end

  defp mint(app_id, opts, now) do
    with {:ok, path} <- private_key_path(opts),
         {:ok, key} <- read_private_key(path),
         {:ok, jwt} <- sign_jwt(app_id, key, now),
         {:ok, installation_id} <- resolve_installation_id(opts, jwt),
         {:ok, token} <- create_installation_token(opts, jwt, installation_id, app_id) do
      :persistent_term.put(@cache_key, token)
      {:ok, token}
    end
  end

  # -- options ---------------------------------------------------------------------------------

  defp app_id(opts) do
    case Keyword.get(opts, :app_id) do
      nil -> {:error, {:missing_option, :app_id}}
      id when is_integer(id) and id > 0 -> {:ok, id}
      id when is_binary(id) -> parse_app_id(String.trim(id))
      other -> {:error, {:invalid_option, :app_id, other}}
    end
  end

  defp parse_app_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, {:invalid_option, :app_id, value}}
    end
  end

  defp private_key_path(opts) do
    case Keyword.get(opts, :private_key_path) do
      nil -> {:error, {:missing_option, :private_key_path}}
      path when is_binary(path) -> present_path(path)
      other -> {:error, {:invalid_option, :private_key_path, other}}
    end
  end

  defp present_path(path) do
    if String.trim(path) == "" do
      {:error, {:invalid_option, :private_key_path, path}}
    else
      {:ok, path}
    end
  end

  # -- key -------------------------------------------------------------------------------------

  defp read_private_key(path) do
    case File.read(path) do
      {:ok, pem} -> decode_private_key(pem, path)
      {:error, reason} -> {:error, {:key_unreadable, path, reason}}
    end
  end

  # Read per mint rather than kept in memory: the point of the file is that the key is not in this
  # process, and a mint happens once an hour.
  defp decode_private_key(pem, path) do
    case decode_rsa(pem) do
      {:ok, key} -> {:ok, key}
      {:error, reason} -> {:error, {:key_undecodable, path, reason}}
    end
  end

  defp decode_rsa(pem) do
    pem
    |> :public_key.pem_decode()
    |> Enum.find(&rsa_key_entry?/1)
    |> decode_found_entry()
  rescue
    error -> {:error, {:pem_decode_failed, Exception.message(error)}}
  end

  defp decode_found_entry(nil), do: {:error, :no_rsa_private_key_entry}
  defp decode_found_entry(entry), do: decode_entry(entry)

  # PKCS#1 ("RSA PRIVATE KEY") and PKCS#8 ("PRIVATE KEY") both decode to the RSAPrivateKey record
  # that `:public_key.sign/3` wants, so either export is accepted.
  defp rsa_key_entry?({tag, _der, _encoding}), do: tag in [:RSAPrivateKey, :PrivateKeyInfo]
  defp rsa_key_entry?(_entry), do: false

  defp decode_entry(entry) do
    case :public_key.pem_entry_decode(entry) do
      {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = key -> {:ok, key}
      _other -> {:error, :not_an_rsa_private_key}
    end
  rescue
    error -> {:error, {:pem_entry_decode_failed, Exception.message(error)}}
  end

  # -- jwt -------------------------------------------------------------------------------------

  defp sign_jwt(app_id, key, now) do
    claims = %{
      "iss" => app_id,
      "iat" => now - @iat_backdate_seconds,
      "exp" => now + @jwt_lifetime_seconds
    }

    signing_input = encode_segment(@jwt_header) <> "." <> encode_segment(claims)

    case sign(signing_input, key) do
      {:ok, signature} ->
        {:ok, signing_input <> "." <> Base.url_encode64(signature, padding: false)}

      {:error, reason} ->
        {:error, {:signing_failed, reason}}
    end
  end

  defp encode_segment(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)

  # RS256 is RSASSA-PKCS1-v1_5 over SHA-256, which is `:sha256` here -- `:public_key.sign/3` with
  # an RSA key emits exactly that.
  defp sign(signing_input, key) do
    {:ok, :public_key.sign(signing_input, :sha256, key)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  # -- installation ----------------------------------------------------------------------------

  defp resolve_installation_id(opts, jwt) do
    case Keyword.get(opts, :installation_id) do
      nil -> discover_installation_id(opts, jwt)
      value -> parse_installation_id(value)
    end
  end

  defp parse_installation_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_installation_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, {:invalid_option, :installation_id, value}}
    end
  end

  defp parse_installation_id(value), do: {:error, {:invalid_option, :installation_id, value}}

  defp discover_installation_id(opts, jwt) do
    with {:ok, account} <- account_option(opts),
         {:ok, body} <- get_json(opts, jwt, "/app/installations"),
         {:ok, installations} <- installation_list(body) do
      select_installation(installations, account)
    end
  end

  defp account_option(opts) do
    case Keyword.get(opts, :account) do
      nil -> {:ok, nil}
      account when is_binary(account) -> {:ok, account}
      other -> {:error, {:invalid_option, :account, other}}
    end
  end

  defp installation_list(body) when is_list(body) do
    {:ok, body |> Enum.map(&normalize_installation/1) |> Enum.reject(&is_nil/1)}
  end

  defp installation_list(_body) do
    {:error, {:malformed_response, "GET /app/installations did not return a JSON array"}}
  end

  defp normalize_installation(%{"id" => id} = raw) when is_integer(id) do
    %{id: id, login: get_in(raw, ["account", "login"])}
  end

  defp normalize_installation(_raw), do: nil

  # No installations at all is the App not being installed; an account that matches nothing is a
  # different problem, and saying which logins do exist is what makes it fixable.
  defp select_installation([], _account), do: {:error, :missing_installation}

  defp select_installation(installations, account) when is_binary(account) do
    case Enum.find(installations, &same_account?(&1.login, account)) do
      nil -> {:error, {:installation_not_found, account, logins(installations)}}
      match -> {:ok, match.id}
    end
  end

  defp select_installation([%{id: id}], _account), do: {:ok, id}

  defp select_installation(installations, _account) do
    {:error, {:ambiguous_installation, logins(installations)}}
  end

  defp same_account?(login, account) when is_binary(login) do
    String.downcase(login) == String.downcase(account)
  end

  defp same_account?(_login, _account), do: false

  defp logins(installations), do: installations |> Enum.map(& &1.login) |> Enum.reject(&is_nil/1)

  # -- token -----------------------------------------------------------------------------------

  defp create_installation_token(opts, jwt, installation_id, app_id) do
    with {:ok, body} <- post_json(opts, jwt, "/app/installations/#{installation_id}/access_tokens") do
      token_from_body(body, installation_id, app_id)
    end
  end

  defp token_from_body(body, installation_id, app_id) when is_map(body) do
    with {:ok, token} <- token_string(body),
         {:ok, expires_at} <- expires_at(body) do
      {:ok, %{token: token, expires_at: expires_at, installation_id: installation_id, app_id: app_id}}
    end
  end

  defp token_from_body(_body, _installation_id, _app_id) do
    {:error, {:malformed_response, "POST access_tokens did not return a JSON object"}}
  end

  defp token_string(%{"token" => token}) when is_binary(token) and token != "", do: {:ok, token}

  defp token_string(_body) do
    {:error, {:malformed_response, "the access token response carried no token"}}
  end

  defp expires_at(%{"expires_at" => raw}) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:malformed_response, "expires_at #{raw}: #{inspect(reason)}"}}
    end
  end

  defp expires_at(_body) do
    {:error, {:malformed_response, "the access token response carried no expires_at"}}
  end

  # -- http ------------------------------------------------------------------------------------

  defp get_json(opts, jwt, path), do: perform(opts, jwt, path, :get, nil)

  defp post_json(opts, jwt, path), do: perform(opts, jwt, path, :post, %{})

  defp perform(opts, jwt, path, method, body) do
    req_opts = [method: method, url: api_url(opts) <> path, headers: headers(jwt)] ++ @req_opts
    req_opts = if is_nil(body), do: req_opts, else: Keyword.put(req_opts, :json, body)

    case request_fun(opts).(req_opts) do
      {:ok, %{status: status, body: response}} when status in 200..299 -> {:ok, response}
      {:ok, %{status: status, body: response}} -> {:error, {:api_status, status, error_message(response)}}
      {:error, reason} -> {:error, {:api_unreachable, reason}}
      other -> {:error, {:api_unreachable, {:unexpected_request_fun_return, other}}}
    end
  rescue
    error -> {:error, {:api_unreachable, Exception.message(error)}}
  end

  defp api_url(opts) do
    opts |> Keyword.get(:api_url, @default_api_url) |> String.trim_trailing("/")
  end

  defp headers(jwt) do
    [
      {"Accept", "application/vnd.github+json"},
      {"Authorization", "Bearer #{jwt}"},
      {"X-GitHub-Api-Version", @api_version},
      {"User-Agent", @user_agent}
    ]
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp error_message(body), do: inspect(body, limit: 10, printable_limit: 200)

  defp request_fun(opts), do: Keyword.get(opts, :request_fun, &default_request/1)

  defp now_fun(opts), do: Keyword.get(opts, :now_fun, fn -> System.system_time(:second) end)

  defp default_request(req_opts) do
    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: decode_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  # A body that will not decode stays a binary, which is how an HTML error page reaches
  # `error_message/1` and a non-JSON 200 reaches `{:malformed_response, _}`.
  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_body(body), do: body
end
