defmodule SymphonyElixir.Shell do
  @moduledoc """
  Locating the POSIX shell that launch commands (`bash -lc`) and workspace hooks (`sh -lc`)
  run in.

  ## Why this module exists (Windows)

  On Windows `System.find_executable("bash")` walks `PATH` and reaches
  `C:\\Windows\\System32\\bash.exe` — **WSL's** bash — before any Git installation. That shell
  runs in a Linux namespace: a Windows path such as `C:/Users/.../fake-codex` is not something it
  can execute, and a Windows executable loses its `.exe` suffix, so `bash -lc "<command>"` exits
  **127** immediately. The port then dies and the caller only sees `{:port_exit, 127}` or
  `:epipe` — which is how dozens of agent-runner and workspace tests failed on a machine where
  bash, Git and codex were all installed and working.

  `%LOCALAPPDATA%\\Microsoft\\WindowsApps\\bash.exe` (the App Execution Alias) is the same WSL
  launcher under a different name and is rejected too.

  Git for Windows ships a POSIX shell that *does* understand Windows paths and `.exe` resolution,
  so it is preferred here; a WSL launcher is rejected outright rather than handed back so the
  failure surfaces as `:bash_not_found` instead of a mystery exit code.

  Nothing changes on non-Windows hosts.
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
