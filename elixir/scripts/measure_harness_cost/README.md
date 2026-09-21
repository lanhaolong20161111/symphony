# measure_harness_cost — 量「同一个提示词、同一个模型网关、不同 harness」的真实花费

三条路都通过 **symphony 自己的 backend** 驱动，所以比的是 harness，不是别的东西：

| 路径 | backend | harness |
|---|---|---|
| `cmd` | `SymphonyElixir.CommandCode.AppServer` | CommandCode 自己的 CLI（`cmd -p`） |
| `codex` | `SymphonyElixir.Codex.AppServer` | codex app-server |
| `dsh` | `SymphonyElixir.ACP.AppServer`（adapter `dsh`） | DeepSeek Harness |

## 为什么需要计量代理

harness 自己的记录里**没有网关侧的计费用量**：

- **codex** 只报自己的口径（`input_tokens` / `cached_input_tokens`）；
- **DSH** 根本不落盘（session 里 `usage` 是 `null`，`dsh-token-meter` 是 `chars/4` 估算）；
- **cmd** 只报**整轮累计**（数不到它内部发了几次请求）。

所以要在 harness 和网关之间夹一层，把网关**原始** usage 记下来。`proxy.mjs` 就是这层，并且两条 wire 都支持：

| wire | usage 形状 |
|---|---|
| `/chat/completions` | `usage.prompt_tokens` + `usage.prompt_tokens_details.cached_tokens` |
| `/responses`（SSE） | 事件里嵌套的 `response.usage.input_tokens` + `input_tokens_details.cached_tokens` |

它是**递归找**第一个"长得像 usage"的对象，而不是只看顶层键 —— 第一次写的时候只找顶层 `usage`，结果 `/responses` 全部记成 `null`，报告里出现"0 请求"的假数据。

## 前置配置（一次性）

### 1) DSH：加一个指向代理的 provider

`~/.dsh/settings.yaml` 的 `llm-pi-ai.providers` 下加（**别改**你正在用的那个 provider）：

```yaml
    commandcode-proxy:
      displayName: CommandCode 网关（计量代理）
      apiKeyEnv: CMD_API_KEY
      api: openai-completions
      baseURL: http://127.0.0.1:8899/provider/v1
      defaultContextWindow: 262144
      defaultMaxTokens: 32768
      models:
        - id: deepseek/deepseek-v4.1-flash
          name: DeepSeek V4.1 Flash (proxy)
          contextWindow: 1000000
```

DSH 的 `settings.yaml` 是**热生效**的（改完不用重启），路由名就是 `["commandcode-proxy","deepseek/deepseek-v4.1-flash"]`，通过 `MEASURE_DSH_ROUTE` 传进来。

### 2) codex：不用改配置文件

`measure.exs` 用 `--config` 覆盖把 provider 指向代理（`MEASURE_PROXY_BASE_URL`）。两个坑都已内建：

- `model_provider="…"` 的**引号不能省**（不带引号时 codex 会忽略它，静默回落到默认 provider —— 表现是"代理一个请求都没收到"）；
- `--config` 声明的 provider **必须带 `name`**，否则 codex 直接拒绝加载配置：`provider name must not be empty`。

### 3) Windows：让 symphony 找到 Git 的 bash

`Shell.find_bash/0` 已经优先 Git for Windows 并拒绝 WSL 的 bash；如果你在别的机器上跑，确认 PATH 里 Git 在 `C:\Windows\System32` 之前，否则 codex 那条路会以 `{:port_exit, 127}` 秒死。

## 运行

```powershell
# 1) 起代理（另开一个终端；它会把原始 usage 追加到日志）
node scripts/measure_harness_cost/proxy.mjs 8899 "$env:TEMP\cc_usage.jsonl"

# 2) 验配置（不花钱）
$env:MEASURE_DRY = "1"
mix run --no-start scripts/measure_harness_cost/measure.exs

# 3) 真跑
Remove-Item Env:\MEASURE_DRY
$env:MEASURE_PROMPT = "把 README.md 的行数写进 notes.md，然后读回来确认，最后只回答数字。"
mix run --no-start scripts/measure_harness_cost/measure.exs
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `MEASURE_PROMPT` | — | **必填**，发出去的提示词 |
| `MEASURE_VARIANTS` | `cmd,codex,dsh` | 跑哪几条 |
| `MEASURE_REPS` | `2` | 每条路跑几次 |
| `MEASURE_MAX_TURNS` | `1` | 配合 `MEASURE_VERIFY` 可测 turns-to-done |
| `MEASURE_SEED` | — | 每轮开始前在工作区里跑的 shell 命令（例如从固定 commit 干净 checkout） |
| `MEASURE_VERIFY` | — | 每轮结束后跑；**退出码 0 = 完工**，不过就续跑 |
| `MEASURE_CONTINUE_PROMPT` | 一句固定文案 | 续跑时发的提示词 |
| `MEASURE_WS_ROOT` | `~/code/symphony-workspaces` | 工作区根（每条路一个子目录） |
| `MEASURE_PROXY_LOG` | `%TEMP%/cc_usage.jsonl` | 代理日志 |
| `MEASURE_PROXY_BASE_URL` | `http://127.0.0.1:8899/provider/v1` | 想量别的网关就改这一行 |
| `MEASURE_MODEL` / `MEASURE_DSH_ROUTE` | `deepseek/deepseek-v4.1-flash` / 对应的 JSON 路由 | |
| `MEASURE_DISCOUNT` | `0.1` | 缓存折扣假设，只影响"等效"列 |
| `MEASURE_DRY` | — | 设 `1` 只打印配置 |

## 报告怎么读

```
路径    运行  轮数  来源        请求  prompt    cached    fresh     output    等效      验收
cmd     1     1     CLI 自报    1     66943     57344     9599      226       15559     通过
codex   1     5     网关        5     73568     72704     864       324       8458      通过
dsh     1     4     网关        4     34050     33280     770       293       4391      通过
```

- **来源**：`网关` = 代理记的原始 usage；`CLI 自报` = harness 自己报的（cmd 无法改 baseURL，只能这样）。
  **这是唯一的跨行口径差异**，比较时务必一起看。
- **fresh** = `prompt − cached`，是**按全价计费**的那部分，也是三条路差别最大的地方。
- **等效** = `fresh + cached×discount + output`。折扣率是估计值；**真实折扣率和单价要查网关的用量面板**（CommandCode 的 Provider 套餐带逐请求用量分析）。
- **验收** = `MEASURE_VERIFY` 的退出码。

## 已知的坑（都踩过）

1. **`/responses` 的 usage 是嵌套的** —— 只找顶层 `usage` 会把 codex 全记成 0 请求。
2. **`model_provider` 的引号**（见上）—— 表现是"代理没收到请求"，不是报错。
3. **`--config` 的 provider 必须带 `name`** —— 否则 codex 拒绝启动。
4. **`codex --profile` 不适用于 `app-server`** —— 只能用 `--config`。
5. **冷启动**：一个全新前缀的首次请求缓存率明显低（codex/DSH 都观察过 9% vs 稳态 98%）。
   要比较稳态，就先预热一轮再计时，或把首轮单独列出来。
6. **cmd 的请求数不可观测** —— CLI 只报整轮累计，所以它的"请求=1"是**一次上报**，不是它真的只发了一次。
7. **PowerShell 重定向会写 UTF-16** —— 别用 `git diff > f`/`node x.mjs > f` 这类写法喂给按 UTF-8 解析的脚本。

## 下一个实验：真实小工单的 turns-to-done 对照

上面量的是"一轮的花费"。真正决定选型的是**「完成同一个真实工单需要几轮 × 每轮花费 + 人工返工」**。`MEASURE_SEED` / `MEASURE_VERIFY` / `MEASURE_MAX_TURNS` 就是为它准备的：

```powershell
$env:MEASURE_PROMPT = @'
在 shell.ex 里给 git_roots/0 补 @doc，并让 find_bash/0 不要重复探测 git 根（用 :persistent_term 缓存）。
要求：mix compile --warnings-as-errors 通过，且 mix test test/symphony_elixir/shell_test.exs 全绿。
'@
# 每次运行都从固定 commit 起一个干净 checkout
$env:MEASURE_SEED   = "git clone --shared --quiet C:/Users/lhl20/code/symphony . && git checkout --quiet 72cd82f"
# 客观验收：两条命令都退出 0 才算完工
$env:MEASURE_VERIFY = "mix deps.get --quiet >/dev/null 2>&1; mix compile --warnings-as-errors && mix test test/symphony_elixir/shell_test.exs"
$env:MEASURE_MAX_TURNS = "8"     # 上限，防止无限续跑
$env:MEASURE_REPS = "3"
mix run --no-start scripts/measure_harness_cost/measure.exs
```

**为什么必须靠外部验收判定续跑**：`tracker.kind: memory` 的工单状态**永远不会变**（适配器只读），所以 `AgentRunner` 的 `continue_with_issue?` 会一直续跑到 `max_turns`。真实环境里"完工"的信号是工单被移到终态（agent 通过 Linear 工具做到），本地没有 linear token 时，用 `MEASURE_VERIFY` 的退出码做等价信号最贴近。

**要记录的三个量**：

1. **轮数**（`轮数` 列）—— 三条路各自要几轮才让验收通过；
2. **总等效 tokens**（把每一轮的 `等效` 加起来）—— 注意轮数多的路可能每轮便宜；
3. **是否需要人工改**（这一列工具给不了，要人判）—— 建议判读三点：diff 是否只动了该动的文件、是否引入了无关改动、验收命令是否真能过（而不是把测试改宽松）。

**必须控制住的变量**：

- 每次运行从**同一个 base commit** 起（`MEASURE_SEED` 里的 `git checkout <sha>`）；
- 每条路各跑 3 次取分布（LLM 方差大，单次不可信）；
- 先各预热一轮再计时（冷启动那一发不属于稳态）；
- 三条路的 `max_turns` 相同（否则比的是预算不是 harness）。

**已知会让结论失真的因素**（结论里必须写明）：

- cmd 的用量是 CLI 自报，另两条是网关原始值；
- 缓存折扣率未知，"等效"是在假设下的量级比较；
- 一次性任务上看不出 harness 的长期价值（taste、检查点、对模型的调优）—— 那需要多任务、多次重复才好判。
