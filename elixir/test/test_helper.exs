# Environment-dependent tests are tagged so that a local run means something. On Windows symlinks
# need Developer Mode, there is no POSIX root to assume, and the remote-worker tests need a
# reachable ssh host; CI runs on Linux, where none of these are excluded.
excluded =
  case :os.type() do
    {:win32, _} -> [:needs_symlinks, :needs_ssh, :posix_paths]
    _ -> []
  end

ExUnit.start(exclude: excluded)
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/fake_acp_agent.exs", __DIR__)
