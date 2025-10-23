defmodule Leggy do
  @moduledoc """
  # Leggy — Mensageria simples, tipada e resiliente com RabbitMQ em Elixir 📨

  O **Leggy** é uma biblioteca que abstrai a comunicação com o RabbitMQ usando a
  biblioteca oficial [`amqp`](https://hex.pm/packages/amqp), oferecendo uma
  camada de tipagem e resiliência de conexão para publicação e consumo de
  mensagens.

  Ela foi projetada para **simplicidade, segurança e previsibilidade**, evitando
  boilerplate e centralizando o controle de canais, schemas e reconexões.

  ---

  ## ✨ Recursos principais

  - **Schemas tipados** (`use Leggy.Schema`)
  Define contratos de mensagens declarativos, com conversão automática de tipos
  e validação de campos obrigatórios.

  - **Publicação e leitura simplificadas** (`publish/1` e `get/1`)
  Basta trabalhar com structs Elixir — o encode/decode é feito de forma
  transparente usando JSON.

  - **Pool de canais AMQP resiliente** (`Leggy.ChannelPool`)
  Gerencia múltiplos canais concorrentes, com reconexão automática em caso de
  falha de rede ou reinício do RabbitMQ.

  - **API declarativa e imutável**
  A macro `use Leggy` gera automaticamente toda a infraestrutura de conexão,
  tornando o uso idêntico a um *repository pattern*.

  ---

  ## ⚙️ Exemplo de uso básico

  ```elixir
  defmodule MyApp.RabbitRepo do
  use Leggy,
    host: "localhost",
    username: "guest",
    password: "guest",
    pool_size: 4
  end

  defmodule MyApp.Schemas.EmailChangeMessage do
  use Leggy.Schema

  schema "user_exchange", "email_queue" do
    field :user, :string
    field :ttl, :integer
    field :valid?, :boolean
    field :requested_at, :datetime
  end
  end

  # Inicializa o pool e cria os recursos no RabbitMQ
  MyApp.RabbitRepo.start_link()
  MyApp.RabbitRepo.prepare(MyApp.Schemas.EmailChangeMessage)

  # Publica uma mensagem
  {:ok, msg} =
  MyApp.RabbitRepo.cast(MyApp.Schemas.EmailChangeMessage, %{
    user: "r2d2",
    ttl: 10,
    valid?: true,
    requested_at: DateTime.utc_now()
  })

  MyApp.RabbitRepo.publish(msg)

  # Consome uma mensagem
  MyApp.RabbitRepo.get(MyApp.Schemas.EmailChangeMessage)
  ```

  ---

  ## 🔧 Configuração (opções aceitas por `use Leggy`)

  | Opção | Tipo | Padrão | Descrição |
  |-------|------|--------|------------|
  | `:host` | `String.t` | **obrigatório** | Endereço do servidor RabbitMQ |
  | `:username` | `String.t` | `"guest"` | Usuário de autenticação |
  | `:password` | `String.t` | `"guest"` | Senha do usuário |
  | `:port` | `integer` | `5672` | Porta AMQP |
  | `:virtual_host` | `String.t` | `"/"` | Virtual host (vhost) |
  | `:pool_size` | `integer` | `4` | Número máximo de canais simultâneos |
  | `:heartbeat` | `integer` | `10` | Intervalo de heartbeat em segundos |
  | `:connection_name` | `String.t` ou `nil` | `nil` | Nome identificador da conexão (visível no painel do RabbitMQ) |

  ---

  ## 📚 API pública

  | Função | Descrição |
  |--------|------------|
  | `prepare(schema)` | Cria *exchange* e *queue* de forma **idempotente**. Se já existirem, nada é alterado. |
  | `cast(schema, map)` | Valida e materializa um struct a partir de um mapa, convertendo tipos automaticamente. |
  | `publish(struct)` | Publica uma mensagem JSON no RabbitMQ. |
  | `get(schema)` | Recupera a próxima mensagem da fila e converte para o struct tipado. |
  | `with_channel_public(fun)` | Executa uma função anônima recebendo um canal AMQP do pool (uso avançado). |

  ---

  ## 🧠 Arquitetura interna

  O `Leggy` mantém um **único processo de conexão AMQP**, gerenciado por
  `Leggy.ChannelPool`.
  Esse pool:

  - Abre N canais de forma concorrente e segura.
  - Mantém um `:queue` de canais disponíveis.
  - Reabre canais que caírem automaticamente.
  - Recria a conexão inteira em caso de `:DOWN` do servidor RabbitMQ.

  Todas as operações (`publish`, `get`, `prepare`) utilizam `with_channel/1`, que
  garante **checkout seguro e devolução automática** do canal, mesmo em caso de
  erro ou exceção.

  ---

  ## 🧩 Estrutura modular

  ```
  Leggy/
  ├── Leggy.Schema      # Macro para definir schemas tipados
  ├── Leggy.Codec       # Encode/decode em JSON
  ├── Leggy.Validator   # Validação e conversão de tipos
  └── Leggy.ChannelPool # Pool de canais com reconexão automática
  ```

  ---

  ## 🧰 Boas práticas

  - Sempre declare **schemas estáveis** — evitar alterar nomes de exchange/queue
  após produção.
  - Prefira usar `prepare/1` na inicialização da aplicação (ex.: no `Application.start/2`).
  - Trate erros de consumo (`{:error, {:cast_failed, reason}}`) logando e
  monitorando requeues em Dead Letter Exchanges (DLX).
  - Se for usar em alta escala, defina `connection_name` para identificar pools no painel RabbitMQ.

  ---

  ## 🧪 Teste local rápido

  Você pode iniciar um RabbitMQ via Docker:

  ```bash
  docker run -d --hostname leggy-rabbit --name leggy-rabbit   -p 5672:5672 -p 15672:15672 rabbitmq:3-management
  ```

  Acesse o painel em [http://localhost:15672](http://localhost:15672)
  Usuário/senha padrão: `guest` / `guest`

  ---

  ## 📜 Licença

  **MIT License** © 2025 [Infleet OpenSource](https://github.com/williamthewill/leggy)
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
              Leggy.Message.process(schema_mod, ch, payload, meta)
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
