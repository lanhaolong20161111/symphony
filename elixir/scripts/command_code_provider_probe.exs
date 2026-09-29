# 真调一次 CommandCode 的 provider API —— 用户给的那段 JS 的 Elixir 等价物
#
# 密钥从 **User 作用域** 读进来（PowerShell 传的），因为这个 shell 的进程环境里看不到它 ——
# 这正是设置页上「User 环境已设置 / 本进程看不到」那一列在说的事。
#
# 注意：改这个文件**不要用 PowerShell 的 Set-Content -Encoding UTF8** ✗ —— PS 5.1 会写 BOM，
# Elixir 报 `unexpected token: "" (U+FEFF)`（本轮踩了三次）。

alias SymphonyElixir.CommandCode.Provider

# `--no-start` 意味着 Req 的 Finch 池没起来 ⇒ 少了这一步，调用会以
# "Failed to lookup telemetry handlers" 的样子失败（不是网络问题，是应用树没起）。
{:ok, _} = Application.ensure_all_started(:req)

IO.puts("BASE_URL=#{Provider.base_url()}")
IO.puts("KEY_PRESENT=#{Provider.api_key() != nil}")

for model <- ["deepseek/deepseek-v4-flash", "deepseek/deepseek-v4.1-flash"] do
  t0 = System.monotonic_time(:millisecond)

  result =
    Provider.responses("Write a haiku about race conditions.",
      model: model,
      # 3000, not 200: these are thinking models, and 200 was spent entirely on reasoning tokens
      # before a single word of the answer was written (measured).
      max_output_tokens: 3000,
      timeout: 120_000
    )

  ms = System.monotonic_time(:millisecond) - t0

  case result do
    {:ok, text} ->
      IO.puts("--- #{model} OK in #{ms}ms")
      IO.puts(text)

    {:error, {:no_text, reason, resp}} ->
      IO.puts("--- #{model} NO TEXT in #{ms}ms: #{reason}")
      IO.puts("    status=#{inspect(resp["status"])} usage=#{inspect(resp["usage"])}")

    {:error, reason} ->
      IO.puts("--- #{model} FAILED in #{ms}ms: #{inspect(reason, printable_limit: 300)}")
  end
end
