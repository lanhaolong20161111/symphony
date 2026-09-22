defmodule SymphonyElixirWeb.BodyParser do
  @moduledoc """
  `Plug.Parsers`, with the failures it raises turned into responses.

  `Plug.Parsers` raises rather than answers: `ParseError` for a malformed body (or one that does not
  decode to a map), `BadEncodingError`, `UnsupportedMediaTypeError`, `RequestTooLargeError`. The
  endpoint had no handler for any of them, so a client sending a JSON array or a broken body got an
  exception instead of a status -- for what is plainly a client mistake.

  Wrapping the parser keeps the fix at the boundary where the input arrives, instead of adding a
  global error handler whose defaults would change how every other exception is rendered -- the
  recorder's endpoint learned both halves of this the hard way and this is the same shape.

  Two details that are easy to get wrong, both measured there: Plug answers some of these itself
  before raising, so an already-sent connection is left alone; and a plug that answers must halt, or
  the router runs the controller against a sent connection and raises `AlreadySentError`.
  """

  @behaviour Plug

  require Logger

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    error in Plug.Parsers.ParseError ->
      answer(conn, 400, "malformed_body", "The request body could not be parsed", error)

    error in Plug.Parsers.BadEncodingError ->
      answer(conn, 400, "bad_encoding", "The request body has bad encoding", error)

    error in Plug.Parsers.UnsupportedMediaTypeError ->
      answer(conn, 415, "unsupported_media_type", "Unsupported media type", error)

    error in Plug.Parsers.RequestTooLargeError ->
      answer(conn, 413, "request_too_large", "The request body is too large", error)
  end

  defp answer(conn, status, code, message, error) do
    Logger.warning("rejecting request body: #{Exception.message(error)}")

    conn =
      if conn.state == :unset do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(%{error: %{code: code, message: message}}))
      else
        conn
      end

    Plug.Conn.halt(conn)
  end
end
