defmodule Leggy.Message do
  @moduledoc """
  Funções internas de manipulação de mensagens RabbitMQ no Leggy.

  Este módulo concentra a lógica comum de:
  - decodificação (`Leggy.Codec.decode/1`)
  - validação/cast (`Leggy.Validator.cast/2`)
  - confirmação (`AMQP.Basic.ack/2`)
  - rejeição (`AMQP.Basic.reject/3`)

  É utilizado internamente por:
  - `Leggy.get/1` (modo **polling**)
  - `Leggy.Consumer` (modo **streaming**)
  """

  @spec process(atom(), AMQP.Channel.t(), binary(), map()) ::
          {:ok, struct()} | {:error, term()}
  def process(schema_mod, ch, payload, meta) when is_atom(schema_mod) do
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
end
