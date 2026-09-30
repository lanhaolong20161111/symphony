defmodule SymphonyElixir.Shell do
  @moduledoc """
  External commands: which shell to use, and how to run one so it cannot hang.

  Two concerns in one module on purpose. They were two (`Shell` located shells, `Janitor.Shell` ran
  them), and the one caller that mattered -- the workspace hook runner -- used neither: it built its
  own `Task.async` + `System.cmd` + `Task.yield`, whose timeout kills the *Elixir task* and leaves
  the operating-system process tree alive. Keeping "find the shell" and "run it with a real deadline"
  together is what stops that from happening a third time.

  ## Why not `System.cmd/3`

  `System.cmd/3` has no timeout. On 2026-09-26 a PowerShell janitor hung for **62 minutes** with
  no child process left alive and a flat CPU: the classic shape of a native command whose process
  exited but whose stdout pipe stayed open, after which the caller waits forever. A whole-round
  watchdog contained it, but that costs a process per round and loses the round.

  `run/3` opens the command as a port instead, so it can read `:os_pid` and **kill the process
  tree** when the deadline passes. One hung call costs one call.

  ## Windows pitfalls (all measured, all in one place so they are not rediscovered)

  * **`bash` on `PATH` is WSL's.** `System.find_executable("bash")` finds
    `C:\\Windows\\System32\\bash.exe` before any Git installation; that shell cannot execute a
    Windows path or resolve `.exe`, and `bash -lc "<command>"` exits **127** immediately. Git's own
    shell is preferred and a WSL launcher is rejected outright, so the failure is `:bash_not_found`
    instead of a mystery exit code.
  * **A backslash is an escape character in `bash -lc`.** `C:\\Users\\me\\tool` becomes
    `C:Usersmetool` and the child dies with 127. `normalize_paths/1` forwards-slashes them.
  * **A killed process is not a killed tree.** There is no `kill -9` equivalent that reaches
    children; `taskkill /PID <pid> /T /F` is the one that does. A survivor holds the stdout pipe
    open, which is the hang described above.
  * **`:hide` is required.** Without it a `cmd.exe` shim's grandchild (the real program) has its
    stdout dropped entirely and the caller sees silence -- measured while building `AcpSdk`.
  * **An absolute path is required** by `:spawn_executable`, so every call resolves first and a
    missing tool is a clean `{:error, {:not_found, _}}` rather than an `:enoent` crash.
  * **`.git` is a file in a git worktree**, not a directory. Anything testing `-d .git` (hooks) or
    `File.dir?(.git)` (this codebase) silently decides a worktree is not a checkout -- see
    `SymphonyElixir.GitWorktree`, and ask git instead of the filesystem.

  Nothing here changes on non-Windows hosts.
  """

  @doc """
  bash for `-lc` launch commands.

  On Windows: `<Git>\\bin\\bash.exe` first — the Git Bash launcher also puts `/usr/bin` and
  `/mingw64/bin` on the child's `PATH`, which the hook and fake-agent scripts rely on for
  `sleep`/`env` — then `<Git>\\usr\\bin\\bash.exe`. Returns `nil` when only a WSL launcher is
  available.
  """
  @spec find_bash() :: String.t() | nil
  def find_bash do
    if windows?() do
      git_shell(["bin/bash.exe", "usr/bin/bash.exe"]) || reject_wsl(System.find_executable("bash"))
    else
      System.find_executable("bash")
    end
  end

  @doc """
  POSIX `sh` for workspace hook scripts.

  Falls back to `find_bash/0`: a hook command is `-lc` either way, so bash is a valid substitute
  when a Git install ships only one of the two.
  """
  @spec find_sh() :: String.t() | nil
  def find_sh do
    if windows?() do
      git_shell(["bin/sh.exe", "usr/bin/sh.exe"]) || find_bash() || reject_wsl(System.find_executable("sh"))
    else
      System.find_executable("sh") || System.find_executable("bash")
    end
  end

  @doc """
  Whether a path is a WSL launcher rather than a shell that can run Windows commands.

  Pure and host-independent on purpose: the Windows branch of `find_bash/0` is the only caller,
  but tests can assert the rule on any platform.
  """
  @spec wsl_launcher?(String.t() | nil) :: boolean()
  def wsl_launcher?(nil), do: false

  def wsl_launcher?(path) when is_binary(path) do
    normalized = path |> String.replace("\\", "/") |> String.downcase()

    String.ends_with?(normalized, "/system32/bash.exe") or
      String.ends_with?(normalized, "/windowsapps/bash.exe")
  end

  @doc """
  Whether this host is Windows.
  """
  @spec windows?() :: boolean()
  def windows?, do: match?({:win32, _}, :os.type())

  # ─── running commands ────────────────────────────────────────────────────────

  @default_timeout 60_000

  @typedoc "Command outcome: stdout plus exit status, or a timeout / lookup failure."
  @type outcome :: {:ok, String.t(), non_neg_integer()} | {:error, :timeout | {:not_found, String.t()}}

  @doc """
  Runs `executable` with an argument **list** and returns `{:ok, stdout, exit_status}`.

  Options: `:timeout` (ms, total, default #{@default_timeout}) and `:cd` (working directory).

  Arguments are a list on purpose. A shell-built string is how a multi-line ticket body once got
  split on whitespace and its fragments were read as command-line flags by `gh`.

  The timeout is a **total deadline**, not an inactivity gap: a command that keeps printing would
  otherwise reset the clock on every chunk and never time out. What the caller asked for is "this
  may take at most N ms", and that is what it gets.
  """
  @spec run(String.t(), [String.t()], keyword()) :: outcome()
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case resolve(executable) do
      nil -> {:error, {:not_found, executable}}
      path -> path |> open_port(args, opts) |> collect([], timeout)
    end
  end

  @doc """
  Runs a command and decodes its stdout as JSON.

  Returns `{:ok, term}` when the command exits 0 and its stdout parses, otherwise
  `{:error, {:exit, status, output}}` or `{:error, {:bad_json, output}}`. `gh` writes a useful
  error message to stdout, so the output is kept in the error.
  """
  @spec run_json(String.t(), [String.t()], keyword()) :: {:ok, term()} | {:error, term()}
  def run_json(executable, args, opts \\ []) do
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

  @doc "True when `executable` resolves on `PATH` (or is an existing absolute path)."
  @spec available?(String.t()) :: boolean()
  def available?(executable), do: resolve(executable) != nil

  # `find_sh/0` and `find_bash/0` return absolute paths, which `System.find_executable/1` is not
  # guaranteed to hand back -- so an existing path is accepted as-is. That keeps one runner for both
  # "a tool on PATH" (`gh`, `git`) and "a shell we located ourselves".
  defp resolve(executable) do
    System.find_executable(executable) ||
      if(String.contains?(executable, ["/", "\\"]) and File.regular?(executable), do: executable)
  end

  defp open_port(path, args, opts) do
    port_opts = [:binary, :exit_status, :stderr_to_stdout, :hide, args: args]

    port_opts =
      case Keyword.get(opts, :cd) do
        nil -> port_opts
        dir -> [{:cd, String.to_charlist(dir)} | port_opts]
      end

    Port.open({:spawn_executable, String.to_charlist(path)}, port_opts)
  end

  defp collect(port, acc, timeout) do
    collect_until(port, acc, System.monotonic_time(:millisecond) + timeout)
  end

  defp collect_until(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect_until(port, [data | acc], deadline)
      {^port, {:exit_status, status}} -> {:ok, IO.iodata_to_binary(Enum.reverse(acc)), status}
    after
      remaining ->
        kill(port)
        {:error, :timeout}
    end
  end

  # Kill the whole tree, the way each platform can. `gh` and `git` spawn helpers, and closing the
  # port only reaps the direct child -- a survivor holds the pipe open, which is exactly the failure
  # this module exists to prevent.
  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> _ = kill_tree(pid)
      _ -> :ok
    end
  catch
    _, _ -> :ok
  after
    safe_close(port)
  end

  @doc """
  Kills `pid` **and the whole process tree under it**.

  The one call that reaches children on Windows is `taskkill /PID <pid> /T /F`; elsewhere the
  direct child goes away with the port and `pkill -TERM -P <pid>` collects what it left behind.

  Public for the same reason it exists at all: a deadline is not the only thing that owns a process
  tree. `InstanceRegistry.stop_instance/2` owns the tree of an instance it started, and it has to
  kill it the same way -- a second implementation of "kill the tree" is how one of them ends up only
  killing the direct child.
  """
  @spec kill_tree(non_neg_integer()) :: :ok | {:error, term()}
  def kill_tree(pid) when is_integer(pid) and pid > 0 do
    {output, status} = kill_command(pid)

    if status == 0 do
      :ok
    else
      {:error, {:kill_exit, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:kill_raised, Exception.message(error)}}
  end

  defp kill_command(pid) do
    if windows?() do
      System.cmd("taskkill", ["/PID", Integer.to_string(pid), "/T", "/F"], stderr_to_stdout: true)
    else
      System.cmd("pkill", ["-TERM", "-P", Integer.to_string(pid)], stderr_to_stdout: true)
    end
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Rewrite Windows path separators in a command string so a POSIX shell cannot eat them.

  A launch command is handed to `bash -lc` as a **script**, where a backslash is an escape
  character: `bash -lc "C:\\Users\\me\\fake-codex app-server"` tries to run
  `C:Usersmefake-codex` and the child dies with exit 127 (the port then reports `:epipe`, which
  hides the cause). Forward slashes are accepted by MSYS *and* by the Windows APIs underneath it,
  so the string is normalized on Windows only. Verified 2026-09-21 against the real Git bash:

  | command form | result |
  |---|---|
  | `C:\\...\\fake-codex app-server` | exit 127, `C:Users...fake-codex: No such file` |
  | `C:\\...\\fake-codex` with doubled backslashes | exit 127 (unchanged) |
  | `C:/.../fake-codex app-server` | **exit 0** |

  Nothing changes on POSIX hosts, where `\\` never appears in a path.
  """
  @spec normalize_paths(String.t()) :: String.t()
  def normalize_paths(command) when is_binary(command) do
    if windows?(), do: String.replace(command, "\\", "/"), else: command
  end

  @doc "The Git for Windows installation roots to probe, most specific first."
  @spec git_roots() :: [String.t()]
  def git_roots do
    from_git =
      case System.find_executable("git") do
        nil ->
          []

        git ->
          # `<root>\cmd\git.exe`, `<root>\bin\git.exe` and `<root>\mingw64\bin\git.exe` all occur
          # in the wild, so probe every ancestor instead of assuming one layout.
          git
          |> Path.dirname()
          |> ancestors(3)
      end

    from_env =
      ["EXEPATH", "GIT_INSTALL_ROOT"]
      |> Enum.map(&System.get_env/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    from_install_dirs =
      ["ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "LOCALAPPDATA"]
      |> Enum.map(&System.get_env/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.flat_map(fn base -> [Path.join(base, "Git"), Path.join(base, "Programs/Git")] end)

    [from_git, from_env, from_install_dirs]
    |> List.flatten()
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp git_shell(relative_candidates) do
    roots = git_roots()

    Enum.find_value(relative_candidates, fn relative ->
      roots
      |> Enum.map(&Path.join(&1, relative))
      |> Enum.find(&File.regular?/1)
    end)
  end

  defp ancestors(path, 0), do: [path]
  defp ancestors(path, depth), do: [path | ancestors(Path.dirname(path), depth - 1)]

  defp reject_wsl(nil), do: nil
  defp reject_wsl(path), do: if(wsl_launcher?(path), do: nil, else: path)
end
