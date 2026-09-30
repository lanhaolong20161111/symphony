defmodule SymphonyElixir.ProjectStatus do
  @moduledoc """
  The registry rows with the live state of the instance behind each one.

  `Projects` answers *what this machine declares*: it parses the workflow files, and its
  `reachable?` flag is a boolean probe. This module answers the other half of the question the
  control plane asks -- which of those declared instances are up **right now**, and how much work
  each is carrying -- and it asks the only thing it is allowed to ask, the instance's own
  `GET /api/v1/state`. No instance's internals are read, and nothing is started or stopped: this is a
  read-only view, and there is deliberately no state file for it to go stale against.

  ## Four states, because two of them are different facts

    * `:up` -- it answered `200` and its own `counts` came back;
    * `:down` -- the connection was **refused**: nothing is listening on the port the file declares;
    * `:unreachable` -- a port is declared and something did not answer in time, or answered
      something that is not the state payload. "There is something there and it will not talk" sends
      the reader somewhere else than "there is nothing there", so they are not merged;
    * `:no_port` -- the file declares no `server.port`, so there is nothing to ask. That is not the
      same as not running, and guessing a port would be inventing a value this system cannot know.

  An instance that answers `200` with its own `error` payload (its snapshot timed out) is `:up` with
  `counts: nil` and the code in `detail` -- it is running, and it said so itself.

  ## The wait is bounded twice

  Req is given a short `receive_timeout`, a short `connect_options` timeout and a short
  `pool_timeout`, all with `retry: false` -- the same reasoning as `RecorderClient`: Req retries
  transport errors with backoff, so probing an instance that is **not running** cost three
  connection attempts, which is the one thing a "which of these are up" table cannot afford. On top
  of that the rows are asked **at once** (`Task.async_stream`, `on_timeout: :kill_task`), so the page
  waits about one timeout in total rather than one timeout per project.

  The HTTP call is injectable (`:client`) because a test must not open a socket; the default is
  `fetch/2`, which is the only function here that talks to the network.
  """

  alias SymphonyElixir.{Projects, Workflow}

  @default_timeout_ms 1_500

  # One page, a handful of projects: enough to overlap the requests, small enough not to open a
  # connection per project on a machine with a long registry.
  @max_concurrency 8

  @typedoc "What the instance's own `counts` said."
  @type counts :: %{
          running: non_neg_integer(),
          retrying: non_neg_integer(),
          blocked: non_neg_integer()
        }

  @typedoc "One row's state. `counts` is nil unless the instance answered with them."
  @type state :: :up | :down | :unreachable | :no_port

  @typedoc "A row's state, with `detail` explaining anything other than a clean `up`."
  @type status :: %{state: state(), counts: counts() | nil, detail: String.t() | nil}

  @doc """
  Every registry entry, each carrying a `:status` and an `:own?` flag.

  `:projects` bypasses the registry read (for a caller that already has the rows, and for tests);
  `:client` replaces the HTTP call, and must answer `{:ok, decoded_json}` or `{:error, term()}`;
  `:timeout` is the per-request budget in milliseconds.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    rows = Keyword.get(opts, :projects) || Projects.list(probe: false)

    rows
    |> Enum.map(&Map.put(&1, :own?, own_project?(&1)))
    |> attach(Keyword.delete(opts, :projects))
  end

  @doc """
  Fills in `:status` on rows that already exist, asking every instance at once.

  Separate from `list/1` so the asking can be exercised (and stubbed) without a registry on disk.
  A row whose port is never answered comes back `:unreachable`, and nothing here raises: a task that
  dies or is killed still yields a row.
  """
  @spec attach([map()], keyword()) :: [map()]
  def attach(rows, opts \\ []) when is_list(rows) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    client = Keyword.get(opts, :client) || (&fetch(&1, timeout))

    statuses =
      rows
      |> Task.async_stream(&status_of(&1, client),
        max_concurrency: @max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(&settle/1)

    Enum.zip_with(rows, statuses, fn row, status -> Map.put(row, :status, status) end)
  rescue
    error -> Enum.map(rows, &Map.put(&1, :status, failed(Exception.message(error))))
  end

  @doc """
  One instance's state, over HTTP, with a bounded timeout and no retry.

  The only network call in this module. A refused connection is `:down`; anything else that goes
  wrong is `:unreachable`, with a short reason a person can act on.
  """
  @spec fetch(String.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def fetch(url, timeout \\ @default_timeout_ms) when is_binary(url) do
    opts = [
      receive_timeout: timeout,
      pool_timeout: timeout,
      connect_options: [timeout: timeout],
      retry: false
    ]

    case Req.get(url, opts) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} -> {:error, {:not_state_payload, body}}
      {:ok, %{status: status}} -> {:error, {:project_http, status}}
      {:error, reason} -> {:error, {:project_unreachable, reason}}
    end
  rescue
    error -> {:error, {:project_probe_raised, Exception.message(error)}}
  end

  defp status_of(row, client) do
    case url(row) do
      nil -> %{state: :no_port, counts: nil, detail: "the workflow file declares no server.port"}
      url -> response_status(call(client, url))
    end
  end

  # The registry already normalises a bind address (`0.0.0.0` is not somewhere to connect to), so the
  # URL it computed is used as-is; the port itself is the one the file declares.
  defp url(row), do: row[:url] || port_url(row[:port])

  defp port_url(port) when is_integer(port), do: "http://127.0.0.1:#{port}"
  defp port_url(_port), do: nil

  # A stub (or a future caller) that raises must not take the table down with it: the row still has
  # an honest state to show.
  defp call(client, url) do
    client.(url <> "/api/v1/state")
  rescue
    error -> {:error, {:project_probe_raised, Exception.message(error)}}
  end

  defp response_status({:ok, %{"counts" => counts}}) when is_map(counts), do: up(counts, nil)
  defp response_status({:ok, body}) when is_map(body), do: up_without_counts(body)
  defp response_status({:ok, body}), do: failed("not a JSON object: #{inspect(body)}")

  defp response_status({:error, {:project_http, status}}),
    do: failed("answered HTTP #{status}, not the state payload")

  defp response_status({:error, {:project_unreachable, reason}}), do: unreachable_status(reason)
  defp response_status({:error, reason}), do: failed(describe(reason))

  defp up(counts, detail), do: %{state: :up, counts: normalize_counts(counts), detail: detail}

  # The instance is running and answered -- but its own snapshot did not come back, so there are no
  # counts to show. Zeroes would be a number the instance never claimed, which is the one thing this
  # table must not do.
  defp up_without_counts(body) do
    %{state: :up, counts: nil, detail: error_code(body) || "the instance returned no counts"}
  end

  defp unreachable_status(reason) do
    %{state: if(refused?(reason), do: :down, else: :unreachable), counts: nil, detail: describe(reason)}
  end

  defp failed(detail), do: %{state: :unreachable, counts: nil, detail: detail}

  # Nothing is listening, which is a fact about the port rather than about the instance: it is the
  # answer that says "this project is not running", so it gets its own state instead of a reason.
  defp refused?(%{reason: reason}), do: reason in [:econnrefused, :ehostunreach, :enetunreach]
  defp refused?(_reason), do: false

  defp describe(%{reason: reason}) when is_atom(reason), do: "no answer: #{reason}"
  defp describe(reason) when is_atom(reason), do: "no answer: #{reason}"
  defp describe(reason), do: inspect(reason)

  defp error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp error_code(_body), do: nil

  defp normalize_counts(counts) when is_map(counts) do
    %{
      running: count(counts["running"]),
      retrying: count(counts["retrying"]),
      blocked: count(counts["blocked"])
    }
  end

  defp count(value) when is_integer(value), do: value
  defp count(_value), do: 0

  # A killed task is the timeout: the row is still rendered, as unreachable.
  defp settle({:ok, status}), do: status
  defp settle({:exit, _reason}), do: failed("no answer in time")

  # The registry and a workflow path are the same path, so "which row is this instance" is a
  # comparison rather than a lookup -- the same comparison `Projects.current/0` makes, without its
  # second registry read.
  defp own_project?(row) do
    is_binary(row[:path]) and Path.expand(row[:path]) == Path.expand(Workflow.workflow_file_path())
  end
end
