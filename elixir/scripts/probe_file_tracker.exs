# 判定 file tracker 到底读不读得到票 —— 绕开应用配置，直接喂 settings。
# 跑法：mix run --no-start probe_file_tracker.exs
#
# ⚠️ 不能用 `alias SymphonyElixir.Tracker.File` —— 那会把 Elixir 标准库的 File 遮蔽掉
#    （第一版就是这么错的：File.exists?/1 直接被解析成了 tracker 模块）。
tracker = SymphonyElixir.Tracker.File

path = "C:/Users/lhl20/code/symphony-tickets"
IO.puts("tickets dir exists? #{File.exists?(path)}")
IO.puts("dir? #{File.dir?(path)} / entries: #{inspect(File.ls!(path))}")

# provider 的键可能是字符串也可能是原子（取决于 config schema 怎么建模）
for provider <- [%{"path" => path}, %{path: path}] do
  settings = %{kind: "file", provider: provider, active_states: ["ready", "in-progress"]}
  IO.puts("\n=== provider = #{inspect(provider)} ===")
  IO.inspect(tracker.validate_config(settings), label: "validate_config")

  case tracker.fetch_issues_by_states(["ready", "in-progress"], settings) do
    {:ok, issues} ->
      IO.puts("fetch OK -> #{length(issues)} 张票")

      Enum.each(issues, fn i ->
        IO.puts(
          "   id=#{inspect(i.id)} identifier=#{inspect(i.identifier)} state=#{inspect(i.state)} dispatchable=#{i.dispatchable} title=#{inspect(i.title)}"
        )
      end)

    other ->
      # 单行打印：多行 inspect 会被外层过滤切碎（上一版就只看到 "{:error,"）
      IO.puts("fetch 返回: " <> inspect(other, limit: :infinity))
  end
end
