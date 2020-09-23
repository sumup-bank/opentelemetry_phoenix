defmodule OpentelemetryPhoenix do
  @moduledoc """
  OpentelemetryPhoenix uses Telemetry handlers to create OpenTelemetry spans.

  ## Usage

  In your application start:

  `OpentelemetryPhoenix.setup()`
  """

  require OpenTelemetry.Tracer
  require OpenTelemetry.Span
  alias OpenTelemetry.{Span, Tracer}

  @type opts :: [endpoint_prefix()]

  @typedoc "The endpoint prefix in your endpoint. Defaults to `[:phoenix, :endpoint]`"
  @type endpoint_prefix :: {:endpoint_prefix, [atom()]}

  @doc """
  Initializes and configures the telemetry handlers.
  """
  @spec setup(opts()) :: :ok
  def setup(opts \\ []) do
    opts = ensure_opts(opts)

    _ = OpenTelemetry.register_application_tracer(:opentelemetry_phoenix)
    attach_endpoint_start_handler(opts)
    attach_endpoint_stop_handler(opts)
    attach_router_start_handler()
    attach_router_dispatch_exception_handler()

    :ok
  end

  defp ensure_opts(opts), do: Keyword.merge(default_opts(), opts)

  defp default_opts do
    [endpoint_prefix: [:phoenix, :endpoint]]
  end

  @doc false
  def attach_endpoint_start_handler(opts) do
    :telemetry.attach(
      {__MODULE__, :endpoint_start},
      opts[:endpoint_prefix] ++ [:start],
      &__MODULE__.handle_endpoint_start/4,
      %{}
    )
  end

  @doc false
  def attach_endpoint_stop_handler(opts) do
    :telemetry.attach(
      {__MODULE__, :endpoint_stop},
      opts[:endpoint_prefix] ++ [:stop],
      &__MODULE__.handle_endpoint_stop/4,
      %{}
    )
  end

  @doc false
  def attach_router_start_handler do
    :telemetry.attach(
      {__MODULE__, :router_dispatch_start},
      [:phoenix, :router_dispatch, :start],
      &__MODULE__.handle_router_dispatch_start/4,
      %{}
    )
  end

  @doc false
  def attach_router_dispatch_exception_handler do
    :telemetry.attach(
      {__MODULE__, :router_dispatch_exception},
      [:phoenix, :router_dispatch, :exception],
      &__MODULE__.handle_router_dispatch_exception/4,
      %{}
    )
  end

  @doc false
  def handle_endpoint_start(_event, _measurements, %{conn: conn}, _config) do
    # TODO: maybe add config for what paths are traced? Via sampler?
    ctx = :ot_propagation.http_extract(conn.req_headers)

    span_name = "HTTP #{conn.method}"

    Tracer.start_span(span_name, %{kind: :SERVER, parent: ctx})

    peer_data = Plug.Conn.get_peer_data(conn)

    user_agent = header_value(conn, "user-agent")
    peer_ip = Map.get(peer_data, :address)

    attributes = [
      "http.client_ip": client_ip(conn),
      "http.host": conn.host,
      "http.method": conn.method,
      "http.scheme": "#{conn.scheme}",
      "http.target": conn.request_path,
      "http.user_agent": user_agent,
      "net.host.ip": to_string(:inet_parse.ntoa(conn.remote_ip)),
      "net.host.port": conn.port,
      "net.peer.ip": to_string(:inet_parse.ntoa(peer_ip)),
      "net.peer.port": peer_data.port,
      "net.transport": :"IP.TCP"
    ]

    Span.set_attributes(attributes)
  end

  def handle_endpoint_stop(_event, _measurements, %{conn: conn}, _config) do
    Span.set_attribute(:"http.status", conn.status)
    :ot_http_status.to_status(conn.status) |> Span.set_status()
    Tracer.end_span()
  end

  def handle_router_dispatch_start(_event, _measurements, meta, _config) do
    Span.update_name("#{meta.conn.method} #{meta.route}")

    attributes = [
      "phoenix.plug": meta.plug,
      "phoenix.action": meta.plug_opts
    ]

    Span.set_attributes(attributes)
  end

  def handle_router_dispatch_exception(
        _event,
        _measurements,
        %{kind: kind, error: %{reason: reason}, stacktrace: stacktrace},
        _config
      ) do
    exception_attrs = [
      type: kind,
      reason: reason,
      stacktrace: Exception.format_stacktrace(stacktrace)
    ]

    Span.add_event("exception", exception_attrs)
  end

  defp client_ip(%{remote_ip: remote_ip} = conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [] ->
        to_string(:inet_parse.ntoa(remote_ip))

      [client | _] ->
        client
    end
  end

  defp header_value(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [] ->
        ""

      [value | _] ->
        value
    end
  end
end