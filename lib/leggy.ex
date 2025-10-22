defmodule Leggy do
  @moduledoc """
  Leggy - Mensageria simples e segura com RabbitMQ em Elixir

  O Leggy é uma biblioteca que abstrai o consumo e publicação de mensagens
  no RabbitMQ usando a biblioteca oficial `amqp`.

  Recursos principais:

  - Schemas tipados (`use Leggy.Schema`) para garantir contratos de mensagens.
  - Publicação e leitura simplificadas via `publish/1` e `get/1`.
  - Pool de canais resiliente, com reconexão automática.
  - Configuração declarativa via macro `__using__/1`.

  ## Exemplo de uso

      defmodule MyApp.RabbitRepo do
        use Leggy,
          host: "localhost",
          username: "guest",
          password: "guest",
          pool_size: 4
      end

      defmodule MyApp.Schemas.EmailChangeMessage do
        use Leggy.Schema

        schema "exchange_name", "queue_name" do
          field :user, :string
          field :ttl, :integer
          field :valid?, :boolean
          field :requested_at, :datetime
        end
      end

  ## Configuração

  Opções aceitas por `use Leggy`:

  - :host (obrigatório)
  - :username (default "guest")
  - :password (default "guest")
  - :port (default 5672)
  - :virtual_host (default "/")
  - :pool_size (default 4)
  - :heartbeat (default 10)

  ## API pública

  - `prepare(schema)` - cria exchange e fila de um schema
  - `cast(schema, map)` - valida e cria struct da mensagem
  - `publish(struct)` - publica struct no RabbitMQ
  - `get(schema)` - recupera mensagem da fila e faz cast automático

  MIT License © 2025 Infleet OpenSource
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      host = Keyword.fetch!(opts, :host)
      username = Keyword.get(opts, :username, "guest")
      password = Keyword.get(opts, :password, "guest")
      port = Keyword.get(opts, :port, 5672)
      virtual_host = Keyword.get(opts, :virtual_host, "/")
      pool_size = Keyword.get(opts, :pool_size, 4)
      heartbeat = Keyword.get(opts, :heartbeat, 10)
      connection_name = Keyword.get(opts, :connection_name, nil)

      @leggy_pool Leggy.ChannelPool

      def child_spec(_arg \\ []) do
        %{
          id: @leggy_pool,
          start:
            {@leggy_pool, :start_link,
             [
               [
                 host: unquote(host),
                 username: unquote(username),
                 password: unquote(password),
                 port: unquote(port),
                 virtual_host: unquote(virtual_host),
                 pool_size: unquote(pool_size),
                 heartbeat: unquote(heartbeat),
                 connection_name: unquote(connection_name)
               ]
             ]},
          type: :supervisor
        }
      end

      def start_link(),
        do:
          Supervisor.start_link([child_spec()],
            strategy: :one_for_one,
            name: Module.concat(__MODULE__, Supervisor)
          )

      @doc """
      Cria a exchange e fila definidas no schema, de forma **idempotente**.
      - Se já existirem, nada é sobrescrito.
      - Se não existirem, são criadas automaticamente.
      """
      def prepare(schema_mod) when is_atom(schema_mod) do
        IO.inspect(schema_mod, label: "Preparing schema 3")

        with_channel(fn ch ->
          exchange = schema_mod.__leggy_exchange__()
          queue = schema_mod.__leggy_queue__()

          # Função auxiliar para checar se existe, usando canal temporário
          check_exists = fn kind, name ->
            case AMQP.Channel.open(ch.conn) do
              {:ok, tmp_ch} ->
                exists =
                  case kind do
                    :exchange ->
                      try do
                        AMQP.Exchange.declare(tmp_ch, name, :direct, passive: true)
                        true
                      catch
                        :exit, _ -> false
                      end

                    :queue ->
                      try do
                        AMQP.Queue.declare(tmp_ch, name, passive: true)
                        true
                      catch
                        :exit, _ -> false
                      end
                  end

                # só tenta fechar se o canal ainda estiver vivo
                if Process.alive?(tmp_ch.pid), do: AMQP.Channel.close(tmp_ch)
                exists

              _ ->
                false
            end
          end

          exchange_exists? = check_exists.(:exchange, exchange)
          queue_exists? = check_exists.(:queue, queue)

          unless exchange_exists? do
            IO.puts("Creating exchange #{exchange}...")
            :ok = AMQP.Exchange.declare(ch, exchange, :direct, durable: true)
          end

          unless queue_exists? do
            IO.puts("Creating queue #{queue}...")
            {:ok, _} = AMQP.Queue.declare(ch, queue, durable: true)
          end

          :ok = AMQP.Queue.bind(ch, queue, exchange, routing_key: queue)
          IO.puts("Exchange and queue prepared successfully!")
          :ok
        end)
      end

      @doc "Valida e materializa struct a partir de map/keyword segundo o schema."
      def cast(schema_mod, data) when is_atom(schema_mod) and (is_map(data) or is_list(data)) do
        Leggy.Validator.cast(schema_mod, data)
      end

      @doc "Publica a struct gerada pelo schema em JSON na exchange/queue definidas."
      def publish(struct) when is_map(struct) do
        schema_mod = struct.__struct__
        exchange = schema_mod.__leggy_exchange__()
        queue = schema_mod.__leggy_queue__()

        payload = Leggy.Codec.encode!(struct)

        with_channel(fn ch ->
          AMQP.Basic.publish(ch, exchange, queue, payload,
            persistent: true,
            content_type: "application/json"
          )

          :ok
        end)
      end

      @doc """
      Recupera a próxima mensagem da fila associada ao schema e faz o cast para a struct.

      Retorna:
      - `{:ok, struct}` se a mensagem for válida;
      - `{:error, reason}` se o cast ou decode falharem.

      Em caso de erro, um *nack* com `requeue: true` é enviado.
      """
      def get(schema_mod) when is_atom(schema_mod) do
        queue = schema_mod.__leggy_queue__()

        with_channel(fn ch ->
          case AMQP.Basic.get(ch, queue, no_ack: false) do
            {:empty, _meta} ->
              {:error, :empty}

            {:ok, payload, meta} ->
              case Leggy.Codec.decode(payload) do
                {:ok, map} ->
                  case Leggy.Validator.cast(schema_mod, map) do
                    {:ok, struct} ->
                      :ok = AMQP.Basic.ack(ch, meta.delivery_tag)
                      {:ok, struct}

                    {:error, reason} ->
                      :ok = AMQP.Basic.reject(ch, meta.delivery_tag, requeue: true)
                      {:error, {:cast_failed, reason}}
                  end

                {:error, decode_err} ->
                  :ok = AMQP.Basic.reject(ch, meta.delivery_tag, requeue: true)
                  {:error, {:decode_failed, decode_err}}
              end
          end
        end)
      end

      @doc false
      def with_channel_public(fun) when is_function(fun, 1), do: with_channel(fun)

      defp with_channel(fun) when is_function(fun, 1) do
        pool = @leggy_pool

        case Leggy.ChannelPool.checkout(pool) do
          {:ok, ch_ref} ->
            try do
              fun.(ch_ref.channel)
            after
              Leggy.ChannelPool.checkin(pool, ch_ref)
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end
end
