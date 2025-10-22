defmodule Leggy.Schema do
  @moduledoc """
  Define o contrato de uma mensagem e gera automaticamente uma struct tipada.

  ## Exemplo

      defmodule MyApp.Schemas.EmailChangeMessage do
        use Leggy.Schema

        schema "exchange_name", "queue_name" do
          field :user, :string
          field :ttl, :integer
          field :valid?, :boolean
          field :requested_at, :datetime
        end
      end

  ## Tipos suportados

  - :string
  - :integer
  - :boolean
  - :datetime

  A macro gera automaticamente `defstruct` e funções auxiliares:
  `__leggy_fields__/0`, `__leggy_exchange__/0`, `__leggy_queue__/0`.
  """

  @doc """
  Importa macros para definir schemas de mensagens.
  """
  defmacro __using__(_opts) do
    quote do
      import Leggy.Schema, only: [schema: 3, field: 2]
      Module.register_attribute(__MODULE__, :leggy_fields, accumulate: true)
      @before_compile Leggy.Schema
    end
  end

  @doc """
  Define o schema com exchange, queue e campos.
  """
  defmacro schema(exchange, queue, do: block) do
    quote do
      @leggy_exchange unquote(exchange)
      @leggy_queue unquote(queue)
      unquote(block)
    end
  end

  @doc """
  Define um campo do schema com nome e tipo.
  """
  defmacro field(name, type) when is_atom(name) and is_atom(type) do
    IO.inspect(name)
    IO.inspect(type)

    quote do
      @leggy_fields {unquote(name), unquote(type)}
    end
  end

  @doc """
  Gera o struct e funções auxiliares antes da compilação do módulo.
  """
  defmacro __before_compile__(env) do
    fields = Module.get_attribute(env.module, :leggy_fields) |> Enum.reverse()

    struct_kv =
      for {k, _t} <- fields do
        {k, nil}
      end

    quote do
      defstruct unquote(struct_kv)

      @doc false
      def __leggy_exchange__(), do: @leggy_exchange

      @doc false
      def __leggy_queue__(), do: @leggy_queue

      @doc false
      def __leggy_fields__(), do: unquote(Macro.escape(fields))
    end
  end
end
