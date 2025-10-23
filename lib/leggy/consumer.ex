defmodule Leggy.Consumer do
  @moduledoc """
  `Leggy.Consumer` — consumidor contínuo e resiliente de mensagens RabbitMQ,
  totalmente integrado à infraestrutura do Leggy.

  Reutiliza o `Leggy.ChannelPool` e a função interna `process/3` do módulo `Leggy.Message`
  para processar mensagens da fila de forma consistente com a função `get/1`
  disponível nos módulos que usam `Leggy`.

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

      if queue_exists?(ch, queue) do
        {:ok, _consumer_tag} = AMQP.Basic.consume(ch, queue, nil, no_ack: false)
        IO.puts("🎧 [Leggy.Consumer] Escutando fila existente #{queue}...")
        loop(ch, handler_fun, schema_mod)
      else
        IO.puts("💥 Fila #{queue} não existe — aguardando criação...")
        :timer.sleep(5000)
        listen(repo, schema_mod, handler_fun)
      end
    end)
  end

  defp queue_exists?(%AMQP.Channel{pid: pid}, queue) do
    try do
      # Faz uma declaração passiva real (não cria, só verifica)
      :amqp_channel.call(pid, {:"queue.declare", 0, queue, true, false, false, false, false, []})
      true
    catch
      :exit, {:server_initiated_close, _code, _reason} ->
        false
    end
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
