defmodule SymphonyElixir.Janitor.Shell do
  @moduledoc """
  Runs external commands for the janitor, with a timeout that actually kills the child.

  ## Why not `System.cmd/3`

  `System.cmd/3` has no timeout. On 2026-09-26 a PowerShell janitor hung for **62 minutes** with
  no child process left alive and a flat CPU: the classic shape of a native command whose process
  exited but whose stdout pipe stayed open, after which the caller waits forever. A whole-round
  watchdog contained it, but that costs a process per round and loses the round.

  This module opens the command as a port, so it can read `:os_pid` and **kill the process tree**
  when the deadline passes. One hung call costs one call.

  ## Windows notes

  * `:hide` is required. Without it a `cmd.exe` shim's grandchild (the real program) has its
    stdout dropped entirely and the caller sees silence -- measured while building `AcpSdk`.
  * An absolute executable path is required by `:spawn_executable`, so every call resolves through
    `System.find_executable/1` and a missing tool is a clean `{:error, {:not_found, _}}` rather
    than an `:enoent` crash.
  """

  @default_timeout 60_000

  @typedoc "Command outcome: stdout plus exit status, or a timeout / lookup failure."
  @type outcome :: {:ok, String.t(), non_neg_integer()} | {:error, :timeout | {:not_found, String.t()}}

  @doc """
  Runs `executable` with an argument **list** and returns `{:ok, stdout, exit_status}`.

  Options: `:timeout` (ms, default #{@default_timeout}) and `:cd` (working directory).

  Arguments are a list on purpose. A shell-built string is how a multi-line ticket body once got
  split on whitespace and its fragments were read as command-line flags by `gh`.
  """
  @spec run(String.t(), [String.t()], keyword()) :: outcome()
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case System.find_executable(executable) do
      nil ->
        {:error, {:not_found, executable}}

      path ->
        path
        |> open_port(args, opts)
        |> collect([], timeout)
    end
  end

  @doc """
  Runs a command and decodes its stdout as JSON.

  Returns `{:ok, term}` when the command exits 0 and its stdout parses, otherwise
  `{:error, {:exit, status, output}}` or `{:error, {:bad_json, output}}`. `gh` writes a useful
  error message to stdout, so the output is kept in the error.
  """
  @spec json(String.t(), [String.t()], keyword()) :: {:ok, term()} | {:error, term()}
  def json(executable, args, opts \\ []) do
    case run(executable, args, opts) do
      {:ok, output, 0} ->
        case JSON.decode(output) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, {:bad_json, output}}
        end

      {:ok, output, status} ->
        {:error, {:exit, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "True when `executable` resolves on `PATH`."
  @spec available?(String.t()) :: boolean()
  def available?(executable), do: System.find_executable(executable) != nil

  defp open_port(path, args, opts) do
    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :hide,
      args: args
    ]

    port_opts =
      case Keyword.get(opts, :cd) do
        nil -> port_opts
        dir -> [{:cd, String.to_charlist(dir)} | port_opts]
      end

    Port.open({:spawn_executable, String.to_charlist(path)}, port_opts)
  end

  defp collect(port, acc, timeout) do
    receive do
      {^port, {:data, data}} -> collect(port, [data | acc], timeout)
      {^port, {:exit_status, status}} -> {:ok, IO.iodata_to_binary(Enum.reverse(acc)), status}
    after
      timeout ->
        kill(port)
        {:error, :timeout}
    end
  end

  # Kill the whole tree: `gh` and `git` spawn helpers, and a survivor would hold the pipe open --
  # which is exactly the failure this module exists to prevent.
  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("taskkill", ["/PID", Integer.to_string(pid), "/T", "/F"], stderr_to_stdout: true)

      _ ->
        :ok
    end
  catch
    _, _ -> :ok
  after
    safe_close(port)
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
