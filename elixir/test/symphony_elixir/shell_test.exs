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
      stub_probe()

      # The injected probe stands in for `System.find_executable/1`, the one filesystem walk
      # `git_roots/0` performs, and reports every call to this test. A second probe would
      # therefore show up as a second message.
      first = Shell.git_roots()
      assert_received :git_executable_probed

      second = Shell.git_roots()
      refute_received :git_executable_probed
      assert second == first
    end

    test "a new run probes again instead of reusing the previous run's roots" do
      stub_probe()

      # One run: the run owner probes once and caches in its own process dictionary.
      Shell.git_roots()
      assert_received :git_executable_probed
      Shell.git_roots()
      refute_received :git_executable_probed

      # A new run is a new process: it must not inherit the earlier run's cached roots.
      Task.async(fn -> Shell.git_roots() end) |> Task.await()
      assert_received :git_executable_probed
    end
  end

  # Swaps the probe behind `git_roots/0` for one that reports every call to the test process, so a
  # cached call (no message) is distinguishable from one that walked the filesystem again.
  defp stub_probe do
    test_pid = self()
    previous = Application.get_env(:symphony_elixir, :shell_find_executable)

    Application.put_env(:symphony_elixir, :shell_find_executable, fn name ->
      send(test_pid, :git_executable_probed)
      System.find_executable(name)
    end)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :shell_find_executable)
        probe -> Application.put_env(:symphony_elixir, :shell_find_executable, probe)
      end
    end)
  end
end
