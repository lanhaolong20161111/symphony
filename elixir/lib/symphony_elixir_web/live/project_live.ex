defmodule SymphonyElixirWeb.ProjectLive do
  @moduledoc """
  Create a project.

  A project **is** a workflow file, so this page is a workflow editor with the fields that matter
  filled in for you: the queue, the three repositories, the workspace root, and the agent route --
  which is in a different place for each backend, and is the thing most easily got wrong by hand.

  ## What it refuses to do quietly

  Every validation here is a way a project can be created and then not run:

    * a **queue another project already claims** -- two orchestrators racing for one ticket queue and
      two janitors mirroring one ticket repository;
    * a **queue directory that does not exist**, or that exists but is not a checkout of the tickets
      repository -- the create path opens the issue first and writes the ticket second, so the first
      of those leaves an issue with no ticket, and the janitor pushes from that directory;
    * a **repository that is not on GitHub**, unless the form is told to create it;
    * a **port another project already listens on**;
    * a **credential the chosen agent needs and this process cannot see** (a warning, because the
      instance that runs it is a different process).

  ## Repositories are provisioned before the file is written

  `gh repo create` is an irreversible side effect on someone else's server, so it happens only when
  the box is ticked, it is always private, and it happens **before** anything is written -- a file
  naming a repository that was never created would look configured and fail on the first task.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Config.Schema.Project
  alias SymphonyElixir.Projects
  alias SymphonyElixirWeb.Layouts

  @backends ["codex", "acp", "commandcode"]
  @adapters ["dsh", "workbuddy"]

  # One short line per mode, keyed by the value the schema accepts. The values themselves are read
  # from `Project.publishes/0`, so a mode added there shows up here -- with a blank line, rather than
  # this page keeping a second list in step by hand.
  @publish_blurbs %{
    "pull_request" => "推一个分支并开 pull request（默认 ✓ 等人看过再落地）",
    "direct" => "直接提交、推送项目自己的 main 分支，不开 pull request ✗（不等人看）"
  }

  @impl true
  def mount(_params, _session, socket) do
    existing = load_existing()

    socket =
      socket
      |> assign(:projects, existing)
      |> assign(:backends, @backends)
      |> assign(:adapters, @adapters)
      |> assign(:publish_choices, publish_choices())
      |> assign(:form, defaults(existing))
      |> assign(:known_models, models_for("dsh"))
      |> assign(:problems, [])
      |> assign(:warnings, [])
      |> assign(:created, nil)
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    form = params |> autofill_repos(socket.assigns.form) |> autofill_port(socket.assigns.projects)

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:known_models, models_for(form["adapter"]))
     |> recheck()}
  end

  @impl true
  def handle_event("create", %{"project" => params}, socket) do
    attrs = attrs(params)

    case Projects.create(attrs, socket.assigns.projects) do
      {:ok, path, notes} ->
        {:noreply,
         socket
         |> assign(:created, %{path: path, notes: notes, start: start_command(attrs)})
         |> assign(:form, defaults(load_existing()))
         |> assign(:problems, [])
         |> assign(:warnings, [])
         |> assign(:error, nil)
         |> assign(:projects, load_existing())}

      {:error, {:invalid, problems}} ->
        {:noreply, socket |> assign(:problems, problems) |> assign(:error, nil)}

      {:error, {:provisioning_failed, reason}} ->
        {:noreply,
         socket
         |> assign(:error, "仓库没备齐，所以**没有**写项目文件：#{describe(reason)}")
         |> assign(:problems, [])}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app-shell">
      <header class="hero-card">
        <div class="hero-main">
          <div>
            <p class="eyebrow">项目</p>
            <h1 class="hero-title">新建项目</h1>
            <p class="hero-copy">
              一个项目**就是**一份 workflow 文件（放在 <code>{registry_dir()}</code>）——
              文件名是项目名，<code>server.port</code> 是它的地址。建完就能在
              <a href="/tasks">任务页</a> 上给它建任务，聚合总览也会自动多一行。
            </p>
          </div>
          <Layouts.page_nav current={:new_project} />
        </div>
      </header>

      <%= if @created do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">建好了</h2>
              <p class="section-copy"><%= @created.path %></p>
            </div>
          </div>
          <%= for note <- @created.notes do %>
            <p class="section-copy"><%= note %></p>
          <% end %>
          <p class="section-copy">启动它：</p>
          <pre class="mono" style="white-space: pre-wrap;"><%= @created.start %></pre>
          <p class="section-copy">
            **一个队列只能属于一个实例** —— 如果这个项目的队列和别的项目重合，启动前先在
            <a href="/">聚合总览</a> 顶部看有没有告警。
          </p>
        </section>
      <% end %>

      <%= if @error do %>
        <section class="error-card">
          <h2 class="error-title">没建成</h2>
          <p class="error-copy"><%= @error %></p>
        </section>
      <% end %>

      <%= if @problems != [] do %>
        <section class="error-card">
          <h2 class="error-title">还差这些</h2>
          <ul class="error-copy">
            <li :for={problem <- @problems} style="white-space: pre-wrap;"><%= problem %></li>
          </ul>
        </section>
      <% end %>

      <%= if @warnings != [] do %>
        <section class="section-card">
          <p class="section-copy" style="color: #a15c00;">
            <%= for warning <- @warnings do %>
              <span style="display: block; white-space: pre-wrap;"><%= warning %></span>
            <% end %>
          </p>
        </section>
      <% end %>

      <section class="section-card">
        <form phx-change="validate" phx-submit="create" class="task-form">
          <div style="display: flex; gap: 0.8rem; flex-wrap: wrap;">
            <label class="form-field" style="flex: 1 1 12rem;">
              <span class="form-label">项目名 *（= 文件名）</span>
              <input type="text" name="project[name]" class="form-input" value={@form["name"]} placeholder="my-app" required />
            </label>
            <label class="form-field" style="flex: 0 1 8rem;">
              <span class="form-label">端口 *</span>
              <input type="text" name="project[port]" class="form-input" value={@form["port"]} />
              <span class="form-hint">
                自动扫的：在 4001–4099 里挑第一个**没被任何东西占用**的
                （真的试着 listen 过 ✓），并跳过常用端口（3000/5173/8080/5432/6379…）
              </span>
            </label>
          </div>

          <label class="form-field">
            <span class="form-label">队列目录 *（票据目录，也是票据仓库的检出）</span>
            <input type="text" name="project[queue]" class="form-input" value={@form["queue"]} placeholder="C:/Users/me/code/my-tickets" />
            <span class="form-hint">
              ⚠️ 这个值会**同时**写进 <code>tracker.provider.path</code>（编排器轮询它）和
              <code>janitor.tickets_path</code>（janitor 镜像它）—— 它们是同一个目录的两种声明，
              只改一个会让实例继续盯着另一个、且不报错 ✗
            </span>
          </label>

          <div style="display: flex; gap: 0.8rem; flex-wrap: wrap;">
            <label class="form-field" style="flex: 1 1 14rem;">
              <span class="form-label">issues 仓库 *（owner/仓库）</span>
              <input type="text" name="project[issues_repo]" class="form-input" value={@form["issues_repo"]} placeholder="me/my-app" />
              <span class="form-hint">
                已按你的 GitHub 前缀预填 ✓ 跟着项目名走（<code>owner/</code> → <code>owner/&lt;名&gt;</code>）✓
                **你改过就不再自动改** ✓<br />
                <input type="checkbox" name="project[create_issues_repo]" value="true" checked={@form["create_issues_repo"] == "true"} />
                不在 GitHub 上就帮我建（私有 ✓）
              </span>
            </label>
            <label class="form-field" style="flex: 1 1 14rem;">
              <span class="form-label">tickets 仓库 *（owner/仓库）</span>
              <input type="text" name="project[tickets_repo]" class="form-input" value={@form["tickets_repo"]} placeholder="me/my-app-tickets" />
              <span class="form-hint">
                同上预填 ✓（默认 <code>owner/&lt;名&gt;-tickets</code>）<br />
                <input type="checkbox" name="project[create_tickets_repo]" value="true" checked={@form["create_tickets_repo"] == "true"} />
                帮我建，并 clone 到上面的队列目录 ✓（janitor 是在**那个目录里**提交推送的）
              </span>
            </label>
          </div>

          <label class="form-field">
            <span class="form-label">代码仓库 *（一行一个；多个就是一个目录里几个子目录）</span>
            <textarea name="project[repos]" class="form-textarea" rows="2" placeholder="me/my-app"><%= @form["repos"] %></textarea>
          </label>

          <label class="form-field">
            <span class="form-label">工作区根目录 *（每个工单一个子目录，会自动创建）</span>
            <input type="text" name="project[workspace_root]" class="form-input" value={@form["workspace_root"]} placeholder="~/code/ws/my-app" />
          </label>

          <fieldset class="form-field" style="border: 0; padding: 0; margin: 0;">
            <legend class="form-label">完工怎么落地 *（写进 <code>project.publish</code>）</legend>
            <label
              :for={{value, blurb} <- @publish_choices}
              style="display: block; margin: 0.25rem 0;"
            >
              <input
                type="radio"
                name="project[publish]"
                value={value}
                checked={@form["publish"] == value}
              />
              <code>{value}</code> —— {blurb}
            </label>
          </fieldset>

          <div style="display: flex; gap: 0.8rem; flex-wrap: wrap;">
            <label class="form-field" style="flex: 1 1 10rem;">
              <span class="form-label">coding agent *</span>
              <select name="project[backend]" class="form-input">
                <option :for={backend <- @backends} value={backend} selected={@form["backend"] == backend}>
                  <%= backend %>
                </option>
              </select>
            </label>
            <%= if @form["backend"] == "acp" do %>
              <label class="form-field" style="flex: 1 1 10rem;">
                <span class="form-label">adapter</span>
                <select name="project[adapter]" class="form-input">
                  <option :for={adapter <- @adapters} value={adapter} selected={@form["adapter"] == adapter}>
                    <%= adapter %>
                  </option>
                </select>
              </label>
            <% end %>
            <label class="form-field" style="flex: 1 1 12rem;">
              <span class="form-label">模型</span>
              <input
                type="text"
                name="project[model]"
                class="form-input"
                value={@form["model"]}
                list="known-models"
                placeholder="auto / 具体模型名"
              />
              <span class="form-hint">
                <%= if @known_models == [] do %>
                  没有可扫的候选 —— 直接手输 ✓
                <% else %>
                  下拉里有 <strong><%= length(@known_models) %></strong> 个候选：这台机器**已经在用的**
                  <%= if @form["adapter"] == "workbuddy" do %>
                    ＋ **workbuddy CLI 自己声明的**（扫它的 <code>--help</code> ✓ 那份列表归它管，抄一份会静默过期 ✗）
                  <% end %>
                  ✓ 也**可以手输** ✓
                <% end %>
              </span>
            </label>
          </div>
          <span class="form-hint">
            <%= case @form["backend"] do %>
              <% "acp" -> %>
                ACP：adapter 和 model 都在 <code>acp:</code> 里 ✓ 票据还能自己覆盖这两项 ✓
                <%= if @form["adapter"] == "dsh" do %>
                  <br />
                  ⚠️ **dsh 的 model 必须是 `session/new` 返回的 `configOptions` 里的条目** ✗
                  （否则被拒 <code>-32602</code> ✓）—— 那只能在会话里拿到 ⇒ 这里扫不出来 ✓
                  所以它给的是"这台机器用过的值" ✓
                <% end %>
              <% "commandcode" -> %>
                CommandCode：模型写在 <code>commandcode.model</code> ✓
              <% _ -> %>
                ⚠️ codex：模型**不在**独立字段里，会被写进 <code>codex.command</code> 这条命令 ✓
                ⇒ 票据上的 model 覆盖在 codex 上**不生效** ✗
            <% end %>
          </span>

          <datalist id="known-models">
            <option :for={model <- @known_models} value={model}></option>
          </datalist>

          <label class="form-field">
            <span class="form-label">环境准备（与语言无关，可留空）</span>
            <textarea name="project[env_prep]" class="form-textarea" rows="2" placeholder="poetry install  /  npm ci  /  ./gradlew build"><%= @form["env_prep"] %></textarea>
            <span class="form-hint">写在 <code>hooks.after_create</code> 的 clone 之后 —— 别假设是 Elixir ✗</span>
          </label>

          <label class="form-field">
            <span class="form-label">提示词（这个项目的规则）</span>
            <textarea name="project[prompt]" class="form-textarea" rows="10"><%= @form["prompt"] %></textarea>
            <span class="form-hint">
              这是 agent 的系统提示词 ✓ "怎么算做完了" 那段尤其重要 ✓
            </span>
          </label>

          <button type="submit" class="task-submit">创建项目</button>
        </form>
      </section>
    </main>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp load_existing do
    Projects.list()
  rescue
    _error -> []
  end

  defp registry_dir do
    Projects.registry_dir()
  rescue
    _error -> "~/code/symphony-projects"
  end

  # A free port, a queue path beside the ones already in use, the GitHub owner this machine already
  # works under, and the prompt skeleton -- so the common case is "type a name" rather than ten
  # fields.
  defp defaults(existing) do
    claimed = existing |> Enum.map(& &1.port) |> Enum.reject(&is_nil/1)
    owner = github_owner()
    prefix = if owner, do: owner <> "/", else: ""

    %{
      "name" => "",
      "port" => port_default(claimed),
      "queue" => Path.join(Path.dirname(Projects.registry_dir()), "my-tickets"),
      "issues_repo" => prefix,
      "tickets_repo" => prefix,
      "create_issues_repo" => "true",
      "create_tickets_repo" => "true",
      "repos" => "",
      "workspace_root" => Path.join(Path.dirname(Projects.registry_dir()), "ws/my-app"),
      "backend" => "acp",
      "adapter" => "dsh",
      "model" => "auto",
      # Preselected: the safe half of the choice, and the schema's own default when a file says
      # nothing at all.
      "publish" => "pull_request",
      "env_prep" => "",
      "prompt" => Projects.default_prompt()
    }
  end

  defp publish_choices do
    Enum.map(Project.publishes(), &{&1, Map.get(@publish_blurbs, &1, "")})
  end

  # `nil` from the scan means the range is full, which the form then says rather than inventing a
  # number that will collide.
  defp port_default(claimed) do
    case Projects.next_free_port(claimed) do
      nil -> ""
      port -> Integer.to_string(port)
    end
  end

  defp github_owner do
    Projects.github_owner()
  rescue
    _error -> nil
  end

  defp models_for(adapter) do
    Projects.known_models(adapter)
  rescue
    _error -> []
  end

  # The two repository fields arrive prefilled with the owner (`owner/`) because that prefix is not
  # something a person should have to retype. Once a project name exists, a field still holding only
  # that prefix becomes `owner/<name>` (and `owner/<name>-tickets`) -- but a field the person has
  # edited is left alone, because guessing over a typed value is worse than an empty one.
  defp autofill_repos(params, previous) do
    owner = github_owner()
    name = String.trim(params["name"] || "")

    if owner == nil or name == "" do
      params
    else
      prefix = owner <> "/"
      suffix = slug(name)

      params
      |> fill_if("issues_repo", previous["issues_repo"], prefix, prefix <> suffix)
      |> fill_if("tickets_repo", previous["tickets_repo"], prefix, prefix <> suffix <> "-tickets")
    end
  end

  defp fill_if(params, key, previous, only_when, replacement) do
    untouched? = params[key] in [nil, "", only_when] or params[key] == previous

    if untouched? and String.starts_with?(to_string(params[key] || ""), only_when) do
      Map.put(params, key, replacement)
    else
      params
    end
  end

  # Project names allow dots and underscores; repository names should not end up with them.
  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.trim("-")
  end

  # A port the scan could not find is worth saying out loud; the field is still editable.
  defp autofill_port(params, existing) do
    claimed = existing |> Enum.map(& &1.port) |> Enum.reject(&is_nil/1)

    if String.trim(params["port"] || "") == "" do
      Map.put(params, "port", port_default(claimed))
    else
      params
    end
  end

  defp attrs(params) do
    %{
      name: text(params["name"]),
      port: parse_int(params["port"]),
      queue: text(params["queue"]),
      issues_repo: text(params["issues_repo"]),
      tickets_repo: text(params["tickets_repo"]),
      create_issues_repo: checked?(params["create_issues_repo"]),
      create_tickets_repo: checked?(params["create_tickets_repo"]),
      repos: parse_repos(params["repos"]),
      workspace_root: text(params["workspace_root"]),
      backend: params["backend"] || "codex",
      adapter: params["adapter"],
      model: text(params["model"]),
      # The mode is passed through as the form sent it; `Projects.render/1` writes the safe default
      # for anything that is not one of `Project.publishes/0`.
      publish: params["publish"],
      env_prep: params["env_prep"] || "",
      prompt: params["prompt"] || ""
    }
  end

  defp text(value), do: String.trim(value || "")
  defp checked?("true"), do: true
  defp checked?(_value), do: false

  defp parse_int(value) do
    case Integer.parse(String.trim(value || "")) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp parse_repos(text) do
    (text || "")
    |> String.split(~r/[\r\n]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp recheck(socket) do
    attrs = attrs(socket.assigns.form)
    existing = socket.assigns.projects

    # The validation is run against the real GitHub here -- this is a page a person is looking at,
    # and "the repository does not exist" is exactly the thing they need to be told before submitting.
    problems =
      case Projects.validate(attrs, existing) do
        :ok -> []
        {:error, problems} -> problems
      end

    socket |> assign(:problems, problems) |> assign(:warnings, Projects.warnings(attrs))
  end

  defp start_command(attrs) do
    """
    escript .\\bin\\symphony #{Projects.registry_dir()}/#{attrs.name}.md `
      --i-understand-that-this-will-be-running-without-the-usual-guardrails `
      --port #{attrs.port}
    """
  end

  defp describe({:gh_exit, status, output}), do: "gh 退出 #{status}：#{String.trim(output)}"
  defp describe({:git_exit, status, output}), do: "git 退出 #{status}：#{String.trim(output)}"
  defp describe({:not_empty, path}), do: "队列目录不是空的、也不是那个仓库的检出：#{path}"
  defp describe({:not_found, tool}), do: "找不到命令：#{tool}"
  defp describe(other), do: inspect(other)
end
