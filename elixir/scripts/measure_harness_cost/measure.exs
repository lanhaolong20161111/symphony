# 比较「同一个提示词、同一个网关、不同 harness」的真实花费。
#
# 三条路都通过 **symphony 自己的 backend** 驱动，所以比的是 harness，不是别的东西：
#   cmd   → SymphonyElixir.CommandCode.AppServer（`cmd -p`，CommandCode 自己的 harness）
#   codex → SymphonyElixir.Codex.AppServer（codex app-server）
#   dsh   → SymphonyElixir.ACP.AppServer（adapter: dsh）
#
# 用量口径：
#   codex / dsh 经**计量代理**取网关原始 usage（需按 README 把 baseURL 指过来）；
#   cmd 的 CLI 不能改 baseURL，所以用它自己 NDJSON 里报的同族字段（inputTokens/cacheReadTokens/…）。
#   报告里会标明每一行数据来自哪一侧。
#
# 用法（在 `elixir/` 目录下）：
#
#   # 1) 起代理（另开一个终端）
#   node scripts/measure_harness_cost/proxy.mjs 8899 "$env:TEMP\cc_usage.jsonl"
#
#   # 2) 配置并跑
#   $env:MEASURE_PROMPT = "把 README.md 的行数写进 notes.md，然后读回来确认"
#   mix run --no-start scripts/measure_harness_cost/measure.exs
#
#   # 只看解析出来的配置、不真跑（不花钱）
#   $env:MEASURE_DRY = "1"; mix run --no-start scripts/measure_harness_cost/measure.exs
#
# 环境变量（都有默认值，见 `config/0`）：
#   MEASURE_PROMPT            必填：发出去的提示词
#   MEASURE_VARIANTS          默认 "cmd,codex,dsh"
#   MEASURE_REPS              默认 2（每条路跑几次）
#   MEASURE_WS_ROOT           默认 ~/code/symphony-workspaces
#   MEASURE_MAX_TURNS         默认 1；配合 MEASURE_VERIFY 可测 turns-to-done
#   MEASURE_SEED              可选：每轮开始前在工作区里跑的 shell 命令（例如从某个 commit 起干净 checkout）
#   MEASURE_VERIFY            可选：每轮结束后跑的 shell 命令；**退出码 0 = 完工**，据此决定是否续跑
#   MEASURE_CONTINUE_PROMPT   可选：续跑时发的提示词（默认一句固定文案）
#   MEASURE_PROXY_LOG         默认 %TEMP%/cc_usage.jsonl
#   MEASURE_DRY               设 1 只打印配置
defmodule MeasureHarnessCost do
  alias SymphonyElixir.Tracker.Issue

  @default_continue "The acceptance command did not pass yet. Continue from the current state and make it pass."

  def run do
    if dry?() do
      IO.puts("DRY RUN —— 只打印配置，不启动任何 harness\n")
      print_config(config())
      System.halt(0)
    end

    if config().prompt == "" do
      IO.puts("!! MEASURE_PROMPT 为空 —— 没什么可跑的")
      System.halt(1)
    end

    print_config(config())
    Process.flag(:trap_exit, true)

    results =
      for variant <- config().variants, rep <- 1..config().reps do
        run_isolated(variant, rep)
      end

    report(results)
    System.halt(0)
  end

  # 端口死去会以 EXIT 传给打开它的进程；用 Task 隔离，别让一条路崩掉整场测量。
  defp run_isolated(variant, rep) do
    task = Task.async(fn -> measure(variant, rep) end)

    case Task.yield(task, config().timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, metric} ->
        metric

      {:exit, reason} ->
        IO.puts("  #{variant} ##{rep}  **进程退出**: #{inspect(reason, limit: 4, printable_limit: 200)}")
        failed(variant, rep, {:exit, reason})

      nil ->
        IO.puts("  #{variant} ##{rep}  **超时**")
        failed(variant, rep, :timeout)
    end
  end

  defp measure(variant, rep) do
    ws = Path.join(config().ws_root, "MEASURE-#{variant}")
    reset_workspace!(ws)
    run_shell(config().seed, ws)
    File.rm_rf(config().proxy_log)
    proxy_before = length(proxy_usage())

    {backend, label} = backend(variant)
    workflow = workflow(variant, ws)
    root = Path.join(System.tmp_dir!(), "measure-#{variant}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    wf = Path.join(root, "WORKFLOW.md")
    File.write!(wf, workflow)
    :ok = SymphonyElixir.Workflow.set_workflow_file_path(wf)

    started = System.monotonic_time(:millisecond)
    {turns, turn_results, messages} = run_turns(backend, ws)
    elapsed = System.monotonic_time(:millisecond) - started

    verify = run_shell(config().verify, ws)

    gateway = proxy_usage() |> Enum.drop(proxy_before)
    cli = cli_usage(messages)

    metric = %{
      variant: label,
      rep: rep,
      turns: turns,
      elapsed_ms: elapsed,
      ok?: Enum.all?(turn_results, &match?({:ok, _}, &1)),
      stop: turn_results |> List.last() |> stop_reason(),
      gateway: gateway,
      cli: cli,
      verify: verify
    }

    File.rm_rf(root)
    IO.puts(one_line(metric))
    metric
  end

  # 一轮 = 一次 run_turn。有 MEASURE_VERIFY 时：跑完验收，**不过就续跑**（最多 MEASURE_MAX_TURNS 轮）。
  # 这是「turns to done」的外部判定 —— memory tracker 的工单状态永远不会变，agent 自己没法宣布完工。
  defp run_turns(backend, ws) do
    issue = %Issue{id: "MEASURE", identifier: "MEASURE", title: config().title, state: "In Progress"}

    case backend.start_session(ws) do
      {:ok, session} ->
        try do
          loop(backend, session, issue, 1, [], [])
        after
          backend.stop_session(session)
        end

      {:error, reason} ->
        {0, [{:error, {:start_session, reason}}], []}
    end
  end

  defp loop(backend, session, issue, turn, results, messages) do
    prompt = if turn == 1, do: config().prompt, else: config().continue_prompt
    parent = self()

    result = backend.run_turn(session, prompt, issue, on_message: fn m -> send(parent, {:ev, m}) end)
    collected = collect([])

    results = results ++ [result]
    messages = messages ++ collected

    done? =
      case result do
        {:ok, _} -> turn >= config().max_turns or verify_passed?()
        _ -> true
      end

    if done?, do: {turn, results, messages}, else: loop(backend, session, issue, turn + 1, results, messages)
  end

  defp verify_passed? do
    case run_shell(config().verify, nil) do
      nil -> true
      {0, _out} -> true
      _ -> false
    end
  end

  # ── 各路的 workflow ────────────────────────────────────────────────────────

  defp workflow(:cmd, ws), do: wf(ws, "commandcode", cmd_yaml())

  defp workflow(:codex, ws),
    do: wf(ws, "codex", codex_yaml())

  defp workflow(:dsh, ws), do: wf(ws, "acp", dsh_yaml())

  defp wf(ws, backend, extra) do
    """
    ---
    tracker:
      kind: memory
    agent:
      backend: #{backend}
      max_turns: 1
    #{extra}
    workspace:
      root: #{config().ws_root}
    ---

    You are an agent working in this repository.
    """
  end

  defp cmd_yaml do
    """
    commandcode:
      cli_path: #{config().cli_path}
      model: #{config().model}
      turn_timeout_ms: 900000
    """
  end

  defp codex_yaml do
    """
    codex:
      command: codex --config 'model_provider="commandcode-proxy"' --config 'model="#{config().model}"' --config 'model_providers.commandcode-proxy.name="commandcode-proxy"' --config 'model_providers.commandcode-proxy.base_url="#{config().proxy_base_url}"' --config 'model_providers.commandcode-proxy.wire_api="responses"' --config 'model_providers.commandcode-proxy.experimental_bearer_token="#{config().api_key}"' app-server
      approval_policy: never
      thread_sandbox: workspace-write
      turn_timeout_ms: 900000
    """
  end

  # DSH 侧要求 ~/.dsh/settings.yaml 里有一个指向代理的 provider（见 README），模型路由用它的名字。
  defp dsh_yaml do
    """
    acp:
      adapter: dsh
      model: '#{config().dsh_route}'
      init_timeout_ms: 180000
      turn_timeout_ms: 900000
    """
  end

  defp backend(:cmd), do: {SymphonyElixir.CommandCode.AppServer, "cmd"}
  defp backend(:codex), do: {SymphonyElixir.Codex.AppServer, "codex"}
  defp backend(:dsh), do: {SymphonyElixir.ACP.AppServer, "dsh"}

  # ── 用量提取 ───────────────────────────────────────────────────────────────

  defp proxy_usage do
    case File.read(config().proxy_log) do
      {:error, _} ->
        []

      {:ok, raw} ->
        raw
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"usage" => %{} = u}} -> [normalize(u)]
            _ -> []
          end
        end)
    end
  end

  # 兼容 /chat/completions（prompt_tokens/cached_tokens）与 /responses（input_tokens/input_tokens_details）
  defp normalize(u) do
    prompt = u["prompt_tokens"] || u["input_tokens"] || 0

    cached =
      get_in(u, ["prompt_tokens_details", "cached_tokens"]) ||
        get_in(u, ["input_tokens_details", "cached_tokens"]) ||
        u["cached_input_tokens"] || u["cache_read_tokens"] || 0

    completion = u["completion_tokens"] || u["output_tokens"] || 0

    %{prompt: prompt, cached: cached, completion: completion}
  end

  # cmd 的 CLI 自报（我的 backend 会发 :token_usage，一轮一条整轮累计）
  defp cli_usage(messages) do
    entries = Enum.filter(messages, &(&1[:event] == :token_usage))

    %{
      count: length(entries),
      prompt: entries |> Enum.map(&(get_in(&1, [:usage, "input_tokens"]) || 0)) |> Enum.sum(),
      cached: entries |> Enum.map(&(get_in(&1, [:usage, "cache_read_tokens"]) || 0)) |> Enum.sum(),
      completion: entries |> Enum.map(&(get_in(&1, [:usage, "output_tokens"]) || 0)) |> Enum.sum()
    }
  end

  defp source(%{gateway: [], cli: %{count: 0}}), do: "无数据"
  defp source(%{gateway: []}), do: "CLI 自报"
  defp source(_m), do: "网关"

  defp prompt_of(m), do: if(m.gateway == [], do: m.cli.prompt, else: sum(m.gateway, & &1.prompt))
  defp cached_of(m), do: if(m.gateway == [], do: m.cli.cached, else: sum(m.gateway, & &1.cached))
  defp completion_of(m), do: if(m.gateway == [], do: m.cli.completion, else: sum(m.gateway, & &1.completion))
  defp requests_of(m), do: if(m.gateway == [], do: m.cli.count, else: length(m.gateway))
  defp fresh_of(m), do: prompt_of(m) - cached_of(m)
  defp equiv_of(m), do: fresh_of(m) + round(cached_of(m) * config().discount) + completion_of(m)

  defp sum(list, fun), do: list |> Enum.map(fun) |> Enum.sum()

  defp stop_reason({:ok, t}), do: t[:stop_reason] || t[:result]
  defp stop_reason({:error, r}), do: {:error, r}
  defp stop_reason(_), do: nil

  # ── 报告 ───────────────────────────────────────────────────────────────────

  defp one_line(m) do
    "  #{String.pad_trailing(m.variant, 6)}##{m.rep}  轮=#{m.turns}  #{String.pad_trailing(source(m), 10)} " <>
      "请求=#{String.pad_trailing(to_string(requests_of(m)), 4)} prompt=#{String.pad_trailing(to_string(prompt_of(m)), 8)} " <>
      "cached=#{String.pad_trailing(to_string(cached_of(m)), 8)} fresh=#{String.pad_trailing(to_string(fresh_of(m)), 7)} " <>
      "out=#{String.pad_trailing(to_string(completion_of(m)), 6)} 等效=#{String.pad_trailing(to_string(equiv_of(m)), 7)} " <>
      "验收=#{verify_label(m)} #{m.elapsed_ms}ms"
  end

  defp verify_label(%{verify: nil}), do: "(未设)"
  defp verify_label(%{verify: {code, _}}), do: if(code == 0, do: "通过", else: "失败(#{code})")

  defp report(results) do
    IO.puts("\n════════ 汇总 ════════")

    IO.puts(
      String.pad_trailing("路径", 8) <>
        String.pad_trailing("运行", 6) <>
        String.pad_trailing("轮数", 6) <>
        String.pad_trailing("来源", 12) <>
        String.pad_trailing("请求", 6) <>
        String.pad_trailing("prompt", 10) <>
        String.pad_trailing("cached", 10) <>
        String.pad_trailing("fresh", 9) <>
        String.pad_trailing("output", 9) <>
        String.pad_trailing("等效", 9) <> "验收"
    )

    Enum.each(results, fn m ->
      IO.puts(
        String.pad_trailing(to_string(m.variant), 8) <>
          String.pad_trailing(to_string(m.rep), 6) <>
          String.pad_trailing(to_string(m.turns), 6) <>
          String.pad_trailing(source(m), 12) <>
          String.pad_trailing(to_string(requests_of(m)), 6) <>
          String.pad_trailing(to_string(prompt_of(m)), 10) <>
          String.pad_trailing(to_string(cached_of(m)), 10) <>
          String.pad_trailing(to_string(fresh_of(m)), 9) <>
          String.pad_trailing(to_string(completion_of(m)), 9) <>
          String.pad_trailing(to_string(equiv_of(m)), 9) <> verify_label(m)
      )
    end)

    IO.puts("\n等效 = fresh + cached×#{config().discount} + output（折扣是估计值；真实折扣率与单价要查网关的用量面板）")

    IO.puts("\n按路径聚合：")

    for variant <- Enum.map(config().variants, &to_string/1) do
      rows = Enum.filter(results, &(to_string(&1.variant) == variant))

      if rows != [] do
        IO.puts(
          "  #{String.pad_trailing(variant, 7)} 轮数#{inspect(Enum.map(rows, & &1.turns))}  " <>
            "fresh合计=#{Enum.sum(Enum.map(rows, &fresh_of/1))}  等效合计=#{Enum.sum(Enum.map(rows, &equiv_of/1))}  " <>
            "验收通过=#{Enum.count(rows, &match?(%{verify: {0, _}}, &1))}/#{length(rows)}"
        )
      end
    end
  end

  # ── 杂项 ───────────────────────────────────────────────────────────────────

  defp reset_workspace!(ws) do
    File.rm_rf(ws)
    File.mkdir_p!(ws)
  end

  # 返回 nil（未配置）或 {exit_code, 输出尾部}
  defp run_shell(nil, _ws), do: nil
  defp run_shell("", _ws), do: nil

  defp run_shell(command, ws) do
    shell = SymphonyElixir.Shell.find_sh() || "sh"
    opts = if ws, do: [cd: ws, stderr_to_stdout: true], else: [stderr_to_stdout: true]

    try do
      {out, code} = System.cmd(shell, ["-lc", command], opts)
      {code, out |> String.trim() |> String.slice(-300, 300)}
    rescue
      e -> {127, Exception.message(e)}
    end
  end

  defp collect(acc) do
    receive do
      {:ev, m} -> collect([m | acc])
    after
      3_000 -> Enum.reverse(acc)
    end
  end

  defp failed(variant, rep, reason) do
    %{
      variant: to_string(variant),
      rep: rep,
      turns: 0,
      elapsed_ms: 0,
      ok?: false,
      stop: reason,
      gateway: [],
      cli: %{count: 0, prompt: 0, cached: 0, completion: 0},
      verify: nil
    }
  end

  defp print_config(c) do
    IO.puts("提示词      : #{inspect(c.prompt, printable_limit: 120)}")
    IO.puts("路径        : #{inspect(c.variants)}  ×  #{c.reps} 次")
    IO.puts("工作区根    : #{c.ws_root}")
    IO.puts("最大轮数    : #{c.max_turns}")
    IO.puts("seed        : #{inspect(c.seed, printable_limit: 100)}")
    IO.puts("verify      : #{inspect(c.verify, printable_limit: 100)}")
    IO.puts("代理日志    : #{c.proxy_log}")
    IO.puts("代理 baseURL: #{c.proxy_base_url}")
    IO.puts("模型        : #{c.model}")
    IO.puts("DSH 路由    : #{c.dsh_route}")
    IO.puts("")
  end

  defp dry?, do: System.get_env("MEASURE_DRY") in ["1", "true", "yes"]

  defp config do
    %{
      prompt: env("MEASURE_PROMPT", ""),
      title: env("MEASURE_TITLE", "measure harness cost"),
      variants: env("MEASURE_VARIANTS", "cmd,codex,dsh") |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1),
      reps: env("MEASURE_REPS", "2") |> String.to_integer(),
      max_turns: env("MEASURE_MAX_TURNS", "1") |> String.to_integer(),
      timeout_ms: env("MEASURE_TIMEOUT_MS", "1800000") |> String.to_integer(),
      ws_root: env("MEASURE_WS_ROOT", Path.join(System.user_home!(), "code/symphony-workspaces")),
      seed: env("MEASURE_SEED", nil),
      verify: env("MEASURE_VERIFY", nil),
      continue_prompt: env("MEASURE_CONTINUE_PROMPT", @default_continue),
      proxy_log: env("MEASURE_PROXY_LOG", Path.join(System.tmp_dir!(), "cc_usage.jsonl")),
      proxy_base_url: env("MEASURE_PROXY_BASE_URL", "http://127.0.0.1:8899/provider/v1"),
      model: env("MEASURE_MODEL", "deepseek/deepseek-v4.1-flash"),
      model_provider: env("MEASURE_PROVIDER", "commandcode-proxy"),
      dsh_route: env("MEASURE_DSH_ROUTE", ~s(["commandcode-proxy","deepseek/deepseek-v4.1-flash"])),
      cli_path:
        env(
          "MEASURE_CLI_PATH",
          Path.join([System.get_env("APPDATA") || "", "npm/node_modules/command-code/dist/index.mjs"])
        ),
      api_key: env("MEASURE_API_KEY", cmd_api_key()),
      discount: env("MEASURE_DISCOUNT", "0.1") |> String.to_float()
    }
  end

  defp env(key, default) do
    case System.get_env(key) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  defp cmd_api_key do
    env_file = Path.expand("~/.dsh/.env")

    case File.read(env_file) do
      {:ok, raw} ->
        case Regex.run(~r/CMD_API_KEY\s*=\s*([A-Za-z0-9_\-\.]+)/, raw) do
          [_, key] -> key
          _ -> ""
        end

      _ ->
        ""
    end
  end
end

MeasureHarnessCost.run()
