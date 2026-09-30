defmodule SymphonyElixirWeb.LayoutsNavTest do
  # async: false -- two tests render a real route, so the endpoint is started under test.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Socket
  alias SymphonyElixirWeb.Layouts

  @endpoint SymphonyElixirWeb.Endpoint

  # The one `<nav>` in this application lives in `Layouts.page_nav/1`, so counting this token counts
  # navigations. That is how "no page shows two navs" is checked rather than asserted by eye.
  @nav "<nav "

  # Every page that renders `page_nav/1` for itself. The dashboard is deliberately absent: it renders
  # no navigation at all, which is upstream's shape, and the layout supplies its one nav instead.
  @pages_with_their_own_nav [
    SymphonyElixirWeb.ControlLive,
    SymphonyElixirWeb.ControlTicketsLive,
    SymphonyElixirWeb.ControlTicketLive,
    SymphonyElixirWeb.TaskLive,
    SymphonyElixirWeb.ProjectLive,
    SymphonyElixirWeb.SettingsLive
  ]

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    config =
      endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), snapshot_timeout_ms: 50)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    :ok
  end

  test "the dashboard gets one navigation from the layout, and it reaches /control" do
    html = get(build_conn(), "/") |> html_response(200)

    assert count(html, @nav) == 1
    assert count(html, ~s(href="/control")) == 1

    # The dashboard's own template is untouched, so its own content is still exactly upstream's.
    assert html =~ "Operations Dashboard"
  end

  test "a page that renders page_nav/1 itself gets no second navigation from the layout" do
    for view <- @pages_with_their_own_nav do
      html = render_component(&Layouts.app/1, %{inner_content: "x", socket: %Socket{view: view}})

      assert count(html, @nav) == 0,
             "#{inspect(view)} already renders page_nav/1, so the layout must add nothing"
    end
  end

  test "/control still renders exactly one navigation" do
    html = get(build_conn(), "/control") |> html_response(200)

    assert count(html, @nav) == 1
  end

  defp count(html, token), do: html |> String.split(token) |> length() |> Kernel.-(1)
end
