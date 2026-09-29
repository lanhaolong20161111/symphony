defmodule SymphonyElixir.CommandCode.ProviderTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CommandCode.Provider

  describe "request_body/3" do
    test "sends only what was asked for" do
      assert Provider.request_body("hi", "deepseek/deepseek-v4-flash", []) == %{
               "model" => "deepseek/deepseek-v4-flash",
               "input" => "hi"
             }
    end

    test "includes the optional fields when given" do
      body =
        Provider.request_body("hi", "m",
          instructions: "be terse",
          max_output_tokens: 64,
          temperature: 0
        )

      assert body["instructions"] == "be terse"
      assert body["max_output_tokens"] == 64
      # Zero is a value, not an absence -- the guard is `nil`, not falsy.
      assert body["temperature"] == 0
    end

    test "accepts a message list as well as a string" do
      messages = [%{"role" => "user", "content" => "hi"}]
      assert Provider.request_body(messages, "m", [])["input"] == messages
    end

    test "merges :extra, so a field the wrapper does not model is still reachable" do
      body = Provider.request_body("hi", "m", extra: %{"stream" => false, "metadata" => %{"a" => 1}})

      assert body["stream"] == false
      assert body["metadata"] == %{"a" => 1}
    end
  end

  describe "output_text/1" do
    # The wire format. `resp.output_text` in the OpenAI SDK is computed from this, not sent.
    @wire %{
      "id" => "resp_1",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{"type" => "output_text", "text" => "first line\n"},
            %{"type" => "output_text", "text" => "second line"}
          ]
        }
      ]
    }

    test "assembles the text from output[].content[]" do
      assert Provider.output_text(@wire) == "first line\nsecond line"
    end

    test "ignores content parts that are not output_text" do
      response = %{
        "output" => [
          %{
            "content" => [
              %{"type" => "reasoning", "text" => "should not appear"},
              %{"type" => "output_text", "text" => "visible"}
            ]
          }
        ]
      }

      assert Provider.output_text(response) == "visible"
    end

    test "prefers a top-level output_text when a server sends one" do
      assert Provider.output_text(Map.put(@wire, "output_text", "convenience")) == "convenience"
    end

    test "spans several output items" do
      response = %{
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => "a"}]},
          %{"content" => [%{"type" => "output_text", "text" => "b"}]}
        ]
      }

      assert Provider.output_text(response) == "ab"
    end

    test "an empty or unexpected response is an empty string, not a crash" do
      assert Provider.output_text(%{"output" => []}) == ""
      assert Provider.output_text(%{}) == ""
      assert Provider.output_text(nil) == ""
      assert Provider.output_text("nonsense") == ""
    end
  end

  describe "empty_text_reason/1" do
    # A 2xx with no text really happens, and the reason is the useful part. Measured against the live
    # provider with max_output_tokens: 200 -- a thinking model spent the entire budget on reasoning
    # and stopped before writing anything.
    test "names reasoning-token exhaustion when that is what happened" do
      response = %{
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "length"},
        "usage" => %{"output_tokens_details" => %{"reasoning_tokens" => 200}}
      }

      reason = Provider.empty_text_reason(response)
      assert reason =~ "200"
      assert reason =~ "reasoning"
      assert reason =~ "max_output_tokens"
    end

    test "a plain length cut-off says just that" do
      response = %{
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "length"},
        "usage" => %{"output_tokens_details" => %{"reasoning_tokens" => 0}}
      }

      assert Provider.empty_text_reason(response) =~ "max_output_tokens"
    end

    test "any other empty response says so without inventing a cause" do
      assert Provider.empty_text_reason(%{"output" => []}) =~ "没有 output_text"
      assert Provider.empty_text_reason(nil) =~ "没有 output_text"
    end
  end

  describe "parameters" do
    test "a missing key is its own error, because that is the confusing case" do
      # The key lives in the process environment, which is not the same as "set on this machine".
      # Saying `:no_api_key` names that, instead of surfacing as a 401 from the provider.
      assert {:error, :no_api_key} = Provider.responses("hi", model: "m", api_key: nil)
    end

    test "a missing model is refused before anything is sent" do
      assert {:error, :no_model} = Provider.responses("hi", api_key: "k")
    end

    test "the base URL is configurable and never has a trailing slash" do
      previous = Application.get_env(:symphony_elixir, :command_code_base_url)

      Application.put_env(:symphony_elixir, :command_code_base_url, "https://example.test/v1/")
      assert Provider.base_url() == "https://example.test/v1"

      if previous,
        do: Application.put_env(:symphony_elixir, :command_code_base_url, previous),
        else: Application.delete_env(:symphony_elixir, :command_code_base_url)
    end
  end
end
