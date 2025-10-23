defmodule Leggy do
  @moduledoc """
  **Leggy** - Mensageria tipada, resiliente e simples com RabbitMQ em Elixir

  Leggy e uma biblioteca que abstrai o consumo e publicacao de mensagens no RabbitMQ,
  trazendo uma API tipada, validada e segura, inspirada em conceitos de Data Schema
  e Repository Pattern.

  Com `Leggy`, voce pode definir contratos de mensagens, validar tipos automaticamente,
  publicar eventos e processar mensagens com consumidores resilientes - tudo com
  poucas linhas de codigo.

  ---

  ## Principais recursos

  - Schemas tipados (`use Leggy.Schema`) - contratos explicitos de mensagens.
  - Validacao automatica via `Leggy.Validator.cast/2`.
  - Publicacao simples com `publish/1` (aceita structs do schema).
  - Consumo continuo com `Leggy.Consumer`, usando handlers personalizados.
  - Pool resiliente de canais com reconexao e isolamento de falhas.
  - Configuracao declarativa via macro `__using__/1`.
  - Funcoes utilitarias como `prepare/1` (idempotente) e `get/1` (modo polling manual).

  ---

  ## Exemplo de uso

  ```elixir
  defmodule MyApp.RabbitRepo do
    use Leggy,
      host: "localhost",
      username: "guest",
      password: "guest",
      pool_size: 4
  end

  defmodule MyApp.Schemas.EmailMessage do
    use Leggy.Schema

    schema "email_exchange", "email_queue" do
      field :user, :string
      field :subject, :string
      field :sent_at, :datetime
    end
  end

  # Criacao da exchange/queue
  MyApp.RabbitRepo.prepare(MyApp.Schemas.EmailMessage)

  # Criacao e envio da mensagem
  {:ok, msg} = MyApp.RabbitRepo.cast(MyApp.Schemas.EmailMessage, %{user: "r2d2", subject: "hi"})
  MyApp.RabbitRepo.publish(msg)
  ```

  ---

  ## Consumo continuo (Consumer)

  O modulo `Leggy.Consumer` pode ser adicionado como worker supervisionado,
  escutando a fila e processando mensagens automaticamente com um handler:

  ```elixir
  children = [
    {MyApp.LeggyRepo, []},
    {Leggy.Consumer, [MyApp.LeggyRepo, MyApp.Schemas.EmailMessage, &MyApp.Handler.handle_email/1]}
  ]
  Supervisor.start_link(children, strategy: :one_for_one)
  ```

  ---

  ## API Publica

  | Funcao | Descricao |
  |--------|------------|
  | `prepare(schema)` | Cria exchange e fila de forma idempotente |
  | `cast(schema, data)` | Valida e transforma dados em struct do schema |
  | `publish(struct)` | Publica struct no RabbitMQ em JSON |
  | `get(schema)` | Recupera proxima mensagem da fila (definida no modulo que usa `Leggy`) |
  | `with_channel_public(fun)` | Executa callback com canal do pool |
  | `Leggy.Consumer` | Worker continuo para processar mensagens |

  ---

  MIT License 2025 - Projeto Leggy (by Infleet OpenSource)
  """

  @doc """
  Macro para definir um módulo *Repository* conectado ao RabbitMQ.
  Aceita as seguintes opções:
  - :host (obrigatório)
  - :username (default "guest")
  - :password (default "guest")
  - :port (default 5672)
  - :virtual_host (default "/")
  - :pool_size (default 4)
  - :heartbeat (default 10)
  - :connection_name (default nil)
  Exemplo de uso:
    defmodule MyApp.RabbitRepo do
      use Leggy,
        host: "localhost",
        username: "guest",
        password: "guest",
        pool_size: 4
    end
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

      def start_link() do
        Supervisor.start_link([child_spec()],
          strategy: :one_for_one,
          name: Module.concat(__MODULE__, Supervisor)
        )
      end

      @doc """
      Cria a exchange e fila definidas no schema, de forma **idempotente**.
      - Se já existirem, nada é sobrescrito.
      - Se não existirem, são criadas automaticamente.
      """
      def prepare(schema_module) when is_atom(schema_module) do
        with_channel(fn ch ->
          exchange = schema_module.__leggy_exchange__()
          queue = schema_module.__leggy_queue__()

          # Função auxiliar para checar se existe, usando canal temporário
          check_exists = fn kind, name ->
            case AMQP.Channel.open(ch.conn) do
              {:ok, tmp_ch} ->
                exists =
                  case kind do
                    :exchange ->
                      try do
                        # Tenta declarar de forma passiva(sem criar)
                        AMQP.Exchange.declare(tmp_ch, name, :direct, passive: true)
                        true
                      catch
                        :exit, _ -> false
                      end

                    :queue ->
                      try do
                        # Tenta declarar de forma passiva(sem criar)
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
            # Cria exchange durável
            :ok = AMQP.Exchange.declare(ch, exchange, :direct, durable: true)
            # Cria DLX associada. Envia mensagens rejeitadas para DLQ(dead-letter queue)
            :ok = AMQP.Exchange.declare(ch, "#{exchange}_dlx", :direct, durable: true)
          end

          unless queue_exists? do
            IO.puts("Creating queue #{queue}...")

            {:ok, _} =
              AMQP.Queue.declare(ch, queue,
                durable: true,
                arguments: [
                  {"x-dead-letter-exchange", :longstr, "#{exchange}_dlx"},
                  {"x-dead-letter-routing-key", :longstr, "#{queue}_dlq"}
                ]
              )

            # Cria fila durável para DLQ
            {:ok, _} = AMQP.Queue.declare(ch, "#{queue}_dlq", durable: true)

            # Vincula a DLQ à exchange de dead letters
            :ok =
              AMQP.Queue.bind(ch, "#{queue}_dlq", "#{exchange}_dlx", routing_key: "#{queue}_dlq")
          end

          # Vincula a fila à exchange
          :ok = AMQP.Queue.bind(ch, queue, exchange, routing_key: queue)
          IO.puts("Exchange and queue prepared successfully!")
          :ok
        end)
      end

      @doc "Valida e materializa struct a partir de map/keyword segundo o schema."
      def cast(schema_module, data)
          when is_atom(schema_module) and (is_map(data) or is_list(data)) do
        Leggy.Validator.cast(schema_module, data)
      end

      @doc "Publica a struct gerada pelo schema em JSON na exchange/queue definidas."
      def publish(struct) when is_map(struct) do
        schema_module = struct.__struct__
        exchange = schema_module.__leggy_exchange__()
        queue = schema_module.__leggy_queue__()

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
      def get(schema_module) when is_atom(schema_module) do
        queue = schema_module.__leggy_queue__()

        with_channel(fn ch ->
          # Desabilita o ack automático, para controlar manualmente o ack/nack em Leggy.Message
          case AMQP.Basic.get(ch, queue, no_ack: false) do
            {:empty, _meta} ->
              {:error, :empty}

            {:ok, payload, meta} ->
              Leggy.Message.process(schema_module, ch, payload, meta)
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
