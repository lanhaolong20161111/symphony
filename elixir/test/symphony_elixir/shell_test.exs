defmodule SymphonyElixir.ShellTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Shell

  describe "wsl_launcher?/1" do
    test "rejects the WSL launcher on both of the paths Windows can resolve it from" do
      assert Shell.wsl_launcher?("C:\\Windows\\System32\\bash.exe")
      assert Shell.wsl_launcher?("c:/windows/system32/bash.exe")
      assert Shell.wsl_launcher?("C:\\Users\\dev\\AppData\\Local\\Microsoft\\WindowsApps\\bash.exe")
    end

    test "accepts a real POSIX shell, and nil" do
      refute Shell.wsl_launcher?("/bin/bash")
      refute Shell.wsl_launcher?("C:\\Program Files\\Git\\bin\\bash.exe")
      refute Shell.wsl_launcher?("C:\\Program Files\\Git\\usr\\bin\\sh.exe")
      refute Shell.wsl_launcher?(nil)
    end
  end

  describe "find_bash/0 and find_sh/0" do
    test "never hand back a WSL launcher" do
      refute Shell.wsl_launcher?(Shell.find_bash())
      refute Shell.wsl_launcher?(Shell.find_sh())
    end

    test "whatever is returned exists" do
      for path <- [Shell.find_bash(), Shell.find_sh()], is_binary(path) do
        assert File.regular?(path), "expected #{path} to be a regular file"
      end
    end
  end

  describe "git_roots/0" do
    test "roots actually contain the shell they are probed for (Windows)" do
      if match?({:win32, _}, :os.type()) do
        if Shell.find_bash() do
          assert Enum.any?(Shell.git_roots(), fn root ->
                   File.regular?(Path.join(root, "bin/bash.exe")) or
                     File.regular?(Path.join(root, "usr/bin/bash.exe"))
                 end)
        end
      else
        assert is_list(Shell.git_roots())
      end
    end

    test "the second call in a run does not touch the disk again" do
      previous = Application.get_env(:symphony_elixir, :shell_probe_module)
      Application.put_env(:symphony_elixir, :shell_probe_module, SymphonyElixir.ShellTest.ProbeStub)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:symphony_elixir, :shell_probe_module)
          module -> Application.put_env(:symphony_elixir, :shell_probe_module, module)
        end
      end)

      # `ProbeStub` stands in for `System.find_executable/1`, the one filesystem walk
      # `git_roots/0` performs, and reports every probe to the calling process. A second
      # probe would therefore show up as a second message.
      first = Shell.git_roots()
      assert_received :git_executable_probed

      second = Shell.git_roots()
      refute_received :git_executable_probed
      assert second == first
    end
  end
end

defmodule SymphonyElixir.ShellTest.ProbeStub do
  @moduledoc false

  @doc """
  Test double for the `System` probe used by `SymphonyElixir.Shell.git_roots/0`.

  Records each probe in the caller's mailbox and then returns the real result, so a test can tell
  a cached call (no message) apart from one that walked the filesystem again.
  """
  @spec find_executable(String.t()) :: String.t() | nil
  def find_executable(name) do
    send(self(), :git_executable_probed)
    System.find_executable(name)
  end
end
