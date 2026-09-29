defmodule SymphonyElixir.CommandCode.Provider do
  @moduledoc """
  CommandCode's **provider API**: the model itself, over HTTP, with no harness around it.

  This is a third way to reach CommandCode models, and the three are worth keeping apart:

    * `SymphonyElixir.CommandCode.AppServer` drives the `cmd` **CLI**, so the agent loop -- tool
      calls and all -- runs inside CommandCode's own harness. One process per turn.
    * the `acp` backend with the `dsh` adapter routes the same models through **DSH's** harness.
      Measured on this machine: DSH re-sends its system prompt and tool schemas on *every* model
      request, including every tool call, and all of it bills (one-line prompt: 16,547 input tokens;
      create a file and read it back: 3 requests, 50,085).
    * this module calls the **model** directly: one request, one response, no tools, no loop.

  Which one is right is a question about the work, not about cost. "Make this repository do X" needs
  a harness. "Turn this text into that text" does not -- and paying for a harness, plus its prompt on
  every call, to get it is waste.

  ## What it deliberately does not do

  No tool calling, no conversation state, no streaming. A model call is stateless: the whole context
  goes in on every request and the caller owns the loop. Growing a harness here would turn it into
  the thing it exists to avoid.

  ## `output_text` is assembled, not read

  The OpenAI SDK's `resp.output_text` is a **client-side convenience**: the wire format is
  `output: [%{"content" => [%{"type" => "output_text", "text" => ...}]}]`. `output_text/1` does the
  same aggregation, and uses a top-level `output_text` when a server does send one.
  """

  require Logger

  @default_base_url "https://api.commandcode.ai/provider/v1"
  @default_timeout 120_000

  @doc "The provider base URL, without a trailing slash."
  @spec base_url() :: String.t()
  def base_url do
    :symphony_elixir
    |> Application.get_env(:command_code_base_url, @default_base_url)
    |> String.trim_trailing("/")
  end

  @doc """
  The API key, from `CMD_API_KEY`.

  Read from the **process** environment, which is not the same thing as "set on this machine": a
  service started from a shell whose environment predates the variable inherits an empty value while
  every status display says the key is set. `SymphonyElixir.Settings.credentials/0` is where that
  difference is visible.
  """
  @spec api_key() :: String.t() | nil
  def api_key do
    case System.get_env("CMD_API_KEY") do
      nil -> nil
      "" -> nil
      key -> key
    end
  end

  @doc """
  `POST /responses` -- the OpenAI-compatible Responses API.

  `input` is a prompt string or a list of message maps. Options:

    * `:model` (**required**) -- e.g. `"deepseek/deepseek-v4-flash"`
    * `:instructions` -- the system-level prompt
    * `:max_output_tokens`, `:temperature`, `:extra` (a map merged into the body)
    * `:timeout` (default #{@default_timeout} ms), `:api_key`
    * `:retry` (default `false`) -- see below

  Returns `{:ok, text}` with the model's text, or `{:error, reason}` where a rejected call carries
  the provider's own message: `{:http_error, status, body}`.

  ## Why retries are off by default

  Req retries transport errors with backoff unless told not to. For a call whose result feeds a
  decision, silently paying for three attempts is the wrong default -- measured elsewhere in this
  codebase, one unreachable local service cost 15 s of backoff on a page that only wanted to display
  a panel. Pass `retry: true` when the call is known to be idempotent and the budget allows it.
  """
  @spec responses(String.t() | [map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def responses(input, opts \\ []) do
    with {:ok, key} <- require_key(opts),
         {:ok, model} <- require_model(opts) do
      body = request_body(input, model, opts)

      case Req.post(base_url() <> "/responses", [json: body] ++ req_opts(key, opts)) do
        {:ok, %{status: status, body: resp}} when status in 200..299 ->
          ok_or_reason(resp, model)

        {:ok, %{status: status, body: resp}} ->
          Logger.warning("command_code: #{model} rejected with #{status}")
          {:error, {:http_error, status, resp}}

        {:error, reason} ->
          Logger.warning("command_code: #{model} transport error #{inspect(reason)}")
          {:error, {:transport, reason}}
      end
    end
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  end

  # Split out of `responses/2` so the happy path and the "2xx with no text" path are one level deep
  # each: a `with` around a `case` around a `case` is three.
  defp ok_or_reason(resp, model) do
    case output_text(resp) do
      "" ->
        reason = empty_text_reason(resp)
        Logger.warning("command_code: #{model} returned no text -- #{reason}")
        {:error, {:no_text, reason, resp}}

      text ->
        Logger.debug("command_code: #{model} -> #{byte_size(text)} bytes of text")
        {:ok, text}
    end
  end

  defp req_opts(key, opts) do
    [
      headers: [{"authorization", "Bearer #{key}"}],
      receive_timeout: Keyword.get(opts, :timeout, @default_timeout),
      retry: Keyword.get(opts, :retry, false)
    ]
  end

  defp require_key(opts) do
    case Keyword.get(opts, :api_key) || api_key() do
      nil -> {:error, :no_api_key}
      key -> {:ok, key}
    end
  end

  defp require_model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> {:ok, model}
      _ -> {:error, :no_model}
    end
  end

  # Built as a plain map so it can be asserted without a network. Only what was asked for is sent:
  # a `nil` field would be a request the caller did not make.
  @doc false
  @spec request_body(String.t() | [map()], String.t(), keyword()) :: map()
  def request_body(input, model, opts) do
    %{"model" => model, "input" => input}
    |> put_unless_nil("instructions", Keyword.get(opts, :instructions))
    |> put_unless_nil("max_output_tokens", Keyword.get(opts, :max_output_tokens))
    |> put_unless_nil("temperature", Keyword.get(opts, :temperature))
    |> Map.merge(Keyword.get(opts, :extra, %{}))
  end

  defp put_unless_nil(body, _key, nil), do: body
  defp put_unless_nil(body, key, value), do: Map.put(body, key, value)

  @doc """
  The model's text, from either shape.

  `output: [%{"content" => [%{"type" => "output_text", "text" => ...}]}]` is the wire format;
  a top-level `output_text` is an SDK convenience some servers also send. Both are accepted so a
  provider that follows either convention works.
  """
  @spec output_text(map() | term()) :: String.t()
  def output_text(%{"output_text" => text}) when is_binary(text), do: text

  def output_text(%{"output" => output}) when is_list(output) do
    output
    |> Enum.flat_map(&content_parts/1)
    |> Enum.join("")
  end

  def output_text(_response), do: ""

  defp content_parts(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "output_text"))
    |> Enum.map(&Map.get(&1, "text", ""))
    |> Enum.filter(&is_binary/1)
  end

  defp content_parts(_item), do: []

  # A 2xx with no text is a real outcome, and the useful part is *why*. Measured 2026-09-29 against the
  # live provider: `max_output_tokens: 200` came back `incomplete` with **all 200 tokens spent on
  # reasoning** -- these are thinking models, and a budget that looks generous for an answer can be
  # consumed before the answer starts.
  @doc false
  @spec empty_text_reason(map() | term()) :: String.t()
  def empty_text_reason(%{"status" => "incomplete"} = resp) do
    reasoning = get_in(resp, ["usage", "output_tokens_details", "reasoning_tokens"])

    case get_in(resp, ["incomplete_details", "reason"]) do
      "length" when is_integer(reasoning) and reasoning > 0 ->
        "输出被长度截断，而且 #{reasoning} 个 token 全花在 reasoning 上" <>
          " ⇒ 加大 max_output_tokens，或关掉 thinking"

      "length" ->
        "输出被 max_output_tokens 截断了 ⇒ 加大它"

      reason ->
        "响应不完整（#{inspect(reason)}）"
    end
  end

  def empty_text_reason(_resp), do: "响应里没有 output_text 片段"
end
