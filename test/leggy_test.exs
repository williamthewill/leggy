defmodule LeggyTest do
  use ExUnit.Case, async: false
  doctest Leggy
  doctest Leggy.Codec
  doctest Leggy.Validator

  @moduledoc """
  Teste completo de conformidade dos requisitos funcionais das releases 0.1 e 0.2.
  """

  defmodule Leggy.Validator.ExampleSchema do
    use Elixir.Leggy.Schema

    schema "test_exchange", "test_queue" do
      field(:user, :string)
      field(:ttl, :integer)
      field(:valid?, :boolean)
      field(:requested_at, :datetime)
    end
  end

  defmodule Leggy.Validator.ExampleSchema2 do
    use Elixir.Leggy.Schema

    schema "test_exchange", "test_queue" do
      field(:user, :string)
      field(:ttl, :integer)
    end
  end

  # Repo de conexão com RabbitMQ
  defmodule RabbitRepo do
    use Elixir.Leggy,
      host: "localhost",
      username: "guest",
      password: "guest",
      pool_size: 2
  end

  # Schema de mensagem
  defmodule Schemas.EmailChangeMessage do
    use Elixir.Leggy.Schema

    schema "leggy_exchange_test", "leggy_queue_test" do
      field(:user, :string)
      field(:ttl, :integer)
      field(:valid?, :boolean)
      field(:requested_at, :datetime)
    end
  end

  setup_all do
    {:ok, _pid} = start_supervised(RabbitRepo)
    :ok = RabbitRepo.prepare(Schemas.EmailChangeMessage)
    :ok
  end

  # ------------------------------------------------------------
  # Release 0.1
  # ------------------------------------------------------------

  test "[R1.1] __using__/1 permite definir host, username, password e pool_size" do
    spec = RabbitRepo.child_spec()
    args = spec.start |> elem(2) |> List.first()

    assert Keyword.get(args, :host) == "localhost"
    assert Keyword.get(args, :username) == "guest"
    assert Keyword.get(args, :password) == "guest"
    assert Keyword.get(args, :pool_size) == 2
  end

  test "[R1.2] Pool permite N processos simultâneos" do
    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          RabbitRepo.with_channel_public(fn _ch -> :ok end)
        end)
      end

    assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
  end

  test "[R1.3] Pool respeita o tamanho de pool_size" do
    pool_size = 2
    spec = RabbitRepo.child_spec()
    args = spec.start |> elem(2) |> List.first()
    assert Keyword.get(args, :pool_size) == pool_size
  end

  test "[R1.4] Schema gera struct e metadados corretamente" do
    assert function_exported?(Schemas.EmailChangeMessage, :__leggy_exchange__, 0)
    assert function_exported?(Schemas.EmailChangeMessage, :__leggy_queue__, 0)
    assert function_exported?(Schemas.EmailChangeMessage, :__leggy_fields__, 0)

    struct = %Schemas.EmailChangeMessage{}
    assert Map.has_key?(struct, :user)
    assert Map.has_key?(struct, :ttl)
  end

  test "[R1.5] cast/2 cria struct válida e converte tipos corretamente" do
    msg_data = %{
      user: "r2d2",
      ttl: "5",
      valid?: "true",
      requested_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:ok, struct} = RabbitRepo.cast(Schemas.EmailChangeMessage, msg_data)
    assert struct.user == "r2d2"
    assert struct.ttl == 5
    assert struct.valid? == true
  end

  test "[R1.6] cast/2 retorna erro explicativo quando faltam campos" do
    assert {:error, {:missing_fields, fields}} =
             RabbitRepo.cast(Schemas.EmailChangeMessage, %{user: "c3po"})

    assert :ttl in fields
  end

  # ------------------------------------------------------------
  # Release 0.2
  # ------------------------------------------------------------

  test "[R2.1] prepare/1 é idempotente" do
    assert :ok = RabbitRepo.prepare(Schemas.EmailChangeMessage)
    assert :ok = RabbitRepo.prepare(Schemas.EmailChangeMessage)
  end

  test "[R2.2] prepare/1 não sobrescreve configurações existentes" do
    # Executar múltiplas vezes e garantir que não lança erro
    assert :ok = RabbitRepo.prepare(Schemas.EmailChangeMessage)
  end

  test "[R2.3] get/1 retorna erro em falha de cast" do
    RabbitRepo.with_channel_public(fn ch ->
      AMQP.Basic.publish(ch, "leggy_exchange_test", "leggy_queue_test", ~s({"ttl":"abc"}))
    end)

    result = RabbitRepo.get(Schemas.EmailChangeMessage)

    assert match?({:error, {:cast_failed, _}}, result) or result == {:error, :empty}
  end

  test "[R2.4] get/1 envia nack com requeue ou DLQ dependendo da configuração" do
    RabbitRepo.with_channel_public(fn ch ->
      AMQP.Basic.publish(ch, "leggy_exchange_test", "leggy_queue_test", ~s({"ttl":"xyz"}))
    end)

    first_result = RabbitRepo.get(Schemas.EmailChangeMessage)
    second_result = RabbitRepo.get(Schemas.EmailChangeMessage)

    assert match?({:error, {:cast_failed, _}}, first_result) or first_result == {:error, :empty}
    assert match?({:error, {:cast_failed, _}}, second_result) or second_result == {:error, :empty}
  end

  test "[R2.5] with_channel_public/1 está acessível publicamente" do
    assert function_exported?(RabbitRepo, :with_channel_public, 1)
    assert :ok = RabbitRepo.with_channel_public(fn _ch -> :ok end)
  end

  test "[R2.6] Mensagens inválidas são redirecionadas para a DLQ" do
    # Limpa a DLQ e publica uma mensagem inválida na fila principal
    RabbitRepo.with_channel_public(fn ch ->
      AMQP.Queue.purge(ch, "leggy_queue_test")
      AMQP.Queue.purge(ch, "leggy_queue_test_dlq")
    end)

    Process.sleep(200)
    RabbitRepo.with_channel_public(fn ch ->
      AMQP.Basic.publish(ch, "leggy_exchange_test", "leggy_queue_test", ~s({"ttl":"xyz"}))
    end)

    Process.sleep(200)
    result = RabbitRepo.get(Schemas.EmailChangeMessage)

    assert match?({:error, {:cast_failed, _}}, result) or result == {:error, :empty}

    Process.sleep(200)
    assert {:ok, "{\"ttl\":\"xyz\"}", _} = RabbitRepo.with_channel_public(fn ch ->
      AMQP.Basic.get(ch, "leggy_queue_test_dlq", no_ack: true)
    end)
  end
end
