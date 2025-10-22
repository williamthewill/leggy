defmodule Leggy.Validator do
  @moduledoc """
  Responsável por validar e materializar structs de mensagens definidas
  pelos schemas do **Leggy**.

  ## Exemplos

      iex> data = %{
      ...>   user: "r2d2",
      ...>   ttl: 10,
      ...>   valid?: true,
      ...>   requested_at: ~U[2025-10-20 21:19:34Z]
      ...> }
      iex> {:ok, struct} = Elixir.Leggy.Validator.cast(Elixir.LeggyTest.Leggy.Validator.ExampleSchema, data)
      iex> struct.ttl
      10

      iex> bad_data = %{user: "c3po", ttl: "invalid", valid?: true, requested_at: ~U[2025-10-20 21:19:34Z]}
      iex> {:error, {:invalid_type, :ttl, :integer, _}} =
      ...>   Elixir.Leggy.Validator.cast(Elixir.LeggyTest.Leggy.Validator.ExampleSchema, bad_data)

      iex> missing_data = %{user: "c3po"}
      iex> {:error, {:missing_fields, fields}} =
      ...>   Elixir.Leggy.Validator.cast(Elixir.LeggyTest.Leggy.Validator.ExampleSchema, missing_data)
      iex> :ttl in fields
      true
  """

  @doc """
  Realiza o cast de um mapa ou keyword list para a struct definida no schema.

    ## Exemplos

      iex> {:ok, struct} =
      ...>   Elixir.Leggy.Validator.cast(Elixir.LeggyTest.Leggy.Validator.ExampleSchema2, %{user: "r2d2", ttl: 2})
      iex> struct.ttl
      2

      iex> {:error, {:invalid_type, :ttl, :integer, _}} =
      ...>   Elixir.Leggy.Validator.cast(Elixir.LeggyTest.Leggy.Validator.ExampleSchema2, %{user: "r2d2", ttl: "abc"})


  """
  def cast(schema_mod, data) do
    fields = schema_mod.__leggy_fields__()
    map = if is_list(data), do: Map.new(data), else: data

    with :ok <- ensure_all_required(fields, map),
         {:ok, typed} <- coerce_and_validate(fields, map) do
      {:ok, struct(schema_mod, typed)}
    else
      {:error, _} = err -> err
    end
  end

  # -----------------------------------------------------------
  # Funções auxiliares privadas
  # -----------------------------------------------------------

  defp ensure_all_required(fields, map) do
    missing =
      fields
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&Map.has_key?(map, &1))

    if missing == [], do: :ok, else: {:error, {:missing_fields, missing}}
  end

  defp coerce_and_validate(fields, map) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {k, type}, {:ok, acc} ->
      val = Map.get(map, k)

      case cast_type(type, val) do
        {:ok, v2} -> {:cont, {:ok, Map.put(acc, k, v2)}}
        {:error, reason} -> {:halt, {:error, {:invalid_type, k, type, reason}}}
      end
    end)
  end

  # -----------------------------------------------------------
  # Conversores de tipo
  # -----------------------------------------------------------

  defp cast_type(:string, v) when is_binary(v), do: {:ok, v}
  defp cast_type(:string, v) when is_integer(v) or is_boolean(v), do: {:ok, to_string(v)}
  defp cast_type(:string, _), do: {:error, :not_string}

  defp cast_type(:integer, v) when is_integer(v), do: {:ok, v}

  defp cast_type(:integer, v) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> {:ok, i}
      _ -> {:error, :not_integer}
    end
  end

  defp cast_type(:integer, _), do: {:error, :not_integer}

  defp cast_type(:boolean, v) when is_boolean(v), do: {:ok, v}

  defp cast_type(:boolean, v) when is_binary(v) do
    case String.downcase(v) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, :not_boolean}
    end
  end

  defp cast_type(:boolean, _), do: {:error, :not_boolean}

  defp cast_type(:datetime, %DateTime{} = dt), do: {:ok, dt}

  defp cast_type(:datetime, v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :not_iso8601_datetime}
    end
  end

  defp cast_type(:datetime, _), do: {:error, :not_datetime}
end
