defmodule Leggy.Consumer do
  @moduledoc """
  `Leggy.Consumer` — consumidor contínuo e resiliente de mensagens RabbitMQ,
  totalmente integrado à infraestrutura do Leggy.

  Reutiliza o `Leggy.ChannelPool` e a função interna `Leggy.Message.process/3`
  para processar mensagens da fila de forma consistente com `Leggy.get/1`.

  Pode ser iniciado manualmente via:
      Leggy.Consumer.start_link(MyRepo, MySchema, &MyHandler.handle/1)

  Ou supervisionado automaticamente:
      {Leggy.Consumer, [MyRepo, MySchema, &MyHandler.handle/1]}
  """

  use Task, restart: :permanent

  @spec start_link(module(), module(), (struct() -> any())) :: {:ok, pid()} | {:error, term()}
  def start_link(repo, schema_mod, handler_fun)
      when is_atom(repo) and is_atom(schema_mod) and is_function(handler_fun, 1) do
    Task.start_link(fn -> listen(repo, schema_mod, handler_fun) end)
  end

  defp listen(repo, schema_mod, handler_fun) do
    repo.with_channel_public(fn ch ->
      queue = schema_mod.__leggy_queue__()

      # Garante que a fila exista e é durável
      {:ok, _} = AMQP.Queue.declare(ch, queue, durable: true)
      {:ok, _consumer_tag} = AMQP.Basic.consume(ch, queue, nil, no_ack: false)

      IO.puts("🎧 [Leggy.Consumer] Escutando fila #{queue}...")
      loop(ch, handler_fun, schema_mod)
    end)
  end

  defp loop(ch, handler_fun, schema_mod) do
    receive do
      {:basic_deliver, payload, meta} ->
        case Leggy.Message.process(schema_mod, ch, payload, meta) do
          {:ok, struct} ->
            safe_handle(handler_fun, struct)

          {:error, reason} ->
            IO.puts("⚠️ Erro ao processar: #{inspect(reason)}")
        end

        loop(ch, handler_fun, schema_mod)

      other ->
        IO.puts("⚠️ Mensagem inesperada: #{inspect(other)}")
        loop(ch, handler_fun, schema_mod)
    after
      5_000 ->
        # evita travar o processo se não chegar mensagem por muito tempo
        Process.sleep(100)
        loop(ch, handler_fun, schema_mod)
    end
  end

  defp safe_handle(fun, msg) do
    try do
      fun.(msg)
    rescue
      e ->
        IO.puts("💥 Erro no handler: #{Exception.message(e)}")
        IO.inspect(__STACKTRACE__, label: "Stacktrace")
    end
  end

  @doc false
  def child_spec([_repo, schema_mod, _handler_fun] = args) do
    %{
      id: {__MODULE__, schema_mod},
      start: {__MODULE__, :start_link, args},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end
end
