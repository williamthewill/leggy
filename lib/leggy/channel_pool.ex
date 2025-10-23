defmodule Leggy.ChannelPool do
  @moduledoc """
  Gerencia um pool de canais AMQP com reconexão automática e controle de concorrência.

  ## Funcionalidades

  - Mantém uma única conexão AMQP ativa.
  - Cria e recicla N canais (conforme :pool_size).
  - Resiliente a desconexões, quedas de canal e processos que morrem sem devolver o canal.

  ## API interna

  - `start_link(opts)` - inicia o pool
  - `checkout/1` - obtém um canal livre
  - `checkin/1` - devolve o canal ao pool

  ## Estados possíveis

  - :queue de canais disponíveis
  - :queue de processos em espera
  - Reconexão automática em 1s se o servidor cair

  Uso interno: o módulo Leggy invoca automaticamente este pool.
  """

  use GenServer

  @doc """
  Referência a um canal do pool.
  """
  defmodule Ref do
    @enforce_keys [:id, :channel]
    defstruct [:id, :channel]
  end

  ## API

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def checkout(server \\ __MODULE__), do: GenServer.call(server, :checkout, :infinity)

  def checkin(server \\ __MODULE__, %Ref{} = ref), do: GenServer.cast(server, {:checkin, ref})

  ## State
  # %{
  #   conn: AMQP.Connection.t | nil,
  #   monitor: ref | nil,
  #   pool: :queue of channel,
  #   size: integer,
  #   waiting: :queue of from,
  #   opts: keyword
  # }

  @impl true
  def init(opts) do
    state = %{
      conn: nil,
      monitor: nil,
      pool: :queue.new(),
      size: Keyword.get(opts, :pool_size, 4),
      waiting: :queue.new(),
      opts: opts
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case open_connection(state.opts) do
      {:ok, conn} ->
        mref = Process.monitor(conn.pid)
        # cria canais
        case build_channels(conn, state.size) do
          {:ok, channels} ->
            pool = Enum.reduce(channels, :queue.new(), &:queue.in/2)
            {:noreply, %{state | conn: conn, monitor: mref, pool: pool}}

          {:error, reason} ->
            Process.demonitor(mref, [:flush])
            retry_later(reason, state)
        end

      {:error, reason} ->
        retry_later(reason, state)
    end
  end

  def handle_info({:DOWN, mref, :process, _pid, _reason}, %{monitor: mref} = state) do
    # conexão caiu
    {:noreply, schedule_reconnect(%{state | conn: nil, monitor: nil, pool: :queue.new()})}
  end

  @impl true
  def handle_call(:checkout, from, %{pool: pool} = state) do
    case :queue.out(pool) do
      {{:value, ch}, pool2} ->
        {:reply, {:ok, %Ref{id: make_ref(), channel: ch}}, %{state | pool: pool2}}

      {:empty, _} ->
        {:noreply, enqueue_waiter(state, from)}
    end
  end

  @impl true
  def handle_cast({:checkin, %Ref{channel: ch}}, state) do
    ch =
      case alive_channel?(ch) do
        true -> ch
        false -> reopen_channel(state.conn)
      end

    new_state =
      case ch do
        {:error, _} ->
          # não volta pro pool; próximo waiter aguarda novo canal após reconexão
          state

        %{} = ch2 ->
          dispatch_or_enqueue(state, ch2)
      end

    {:noreply, new_state}
  end

  ## helpers

  defp open_connection(opts) do
    params = [
      host: Keyword.fetch!(opts, :host),
      username: Keyword.get(opts, :username, "guest"),
      password: Keyword.get(opts, :password, "guest"),
      port: Keyword.get(opts, :port, 5672),
      virtual_host: Keyword.get(opts, :virtual_host, "/"),
      heartbeat: Keyword.get(opts, :heartbeat, 10)
    ]

    params =
      case Keyword.get(opts, :connection_name) do
        nil -> params
        name -> Keyword.put(params, :client_properties, [{"connection_name", :longstr, name}])
      end

    AMQP.Connection.open(params)
  end

  defp build_channels(conn, n) when n > 0 do
    channels =
      for _ <- 1..n do
        case AMQP.Channel.open(conn) do
          {:ok, ch} -> ch
          {:error, reason} -> {:error, reason}
        end
      end

    case Enum.any?(channels, &match?({:error, _}, &1)) do
      true ->
        {:error, :failed_to_open_all_channels}

      false ->
        {:ok, channels}
    end
  end

  defp alive_channel?(%{pid: pid}) when is_pid(pid), do: Process.alive?(pid)
  defp alive_channel?(_), do: false

  defp reopen_channel(nil), do: {:error, :no_connection}

  defp reopen_channel(conn) do
    case AMQP.Channel.open(conn) do
      {:ok, ch} -> ch
      {:error, r} -> {:error, r}
    end
  end

  defp enqueue_waiter(%{waiting: q} = state, from), do: %{state | waiting: :queue.in(from, q)}

  defp dispatch_or_enqueue(%{waiting: q} = state, ch) do
    case :queue.out(q) do
      {{:value, from}, q2} ->
        GenServer.reply(from, {:ok, %Ref{id: make_ref(), channel: ch}})
        state = %{state | waiting: q2}
        state

      {:empty, _} ->
        %{state | pool: :queue.in(ch, state.pool)}
    end
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, 1_000)
    state
  end

  defp retry_later(_reason, state), do: {:noreply, schedule_reconnect(state)}
end
