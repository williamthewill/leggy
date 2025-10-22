defmodule Leggy.Codec do
  @moduledoc """
  Módulo responsável por serializar e desserializar mensagens JSON utilizadas
  pela biblioteca **Leggy**.

  Ele converte structs Elixir em JSON (via `encode!/1`) e reconverte JSON em maps
  atomizados (via `decode/1`), tratando automaticamente campos `DateTime`.

  ## Exemplo completo

      iex> alias Leggy.Codec
      iex> data = %{
      ...>   user: "r2d2",
      ...>   ttl: 5,
      ...>   valid?: true,
      ...>   requested_at: ~U[2025-10-20 21:19:34Z]
      ...> }
      iex> json = Codec.encode!(data)
      iex> is_binary(json)
      true
      iex> {:ok, decoded} = Codec.decode(json)
      iex> decoded.user
      "r2d2"
      iex> decoded.ttl
      5
      iex> decoded.valid?
      true
  """

  @doc """
  Codifica uma struct ou map em JSON, convertendo automaticamente campos `DateTime`
  para o formato ISO8601.

  ## Exemplos

      iex> alias Leggy.Codec
      iex> data = %{
      ...>   user: "c3po",
      ...>   ttl: 3,
      ...>   requested_at: ~U[2025-10-20 21:19:34Z]
      ...> }
      iex> json = Codec.encode!(data)
      iex> json =~ ~s("user":"c3po")
      true
      iex> json =~ "2025-10-20T21:19:34Z"
      true
  """
  def encode!(struct) do
    struct
    |> Enum.into(%{}, fn
      {k, %DateTime{} = dt} -> {k, DateTime.to_iso8601(dt)}
      kv -> kv
    end)
    |> Jason.encode!()
  end

  @doc """
  Converte JSON em map atomizado, desserializando ISO8601 em DateTime.

  ## Exemplos

      iex> alias Leggy.Codec
      iex> json = ~s({"user":"r2d2","ttl":5,"requested_at":"2025-10-20T21:19:34Z"})
      iex> {:ok, decoded} = Codec.decode(json)
      iex> decoded.user
      "r2d2"
      iex> decoded.ttl
      5
      iex> is_map(decoded)
      true
      iex> decoded.requested_at
      "2025-10-20T21:19:34Z"

      iex> alias Leggy.Codec
      iex> result = Codec.decode("invalid_json")
      iex> match?({:error, _}, result)
      true
  """
  def decode(payload) when is_binary(payload) do
    case Jason.decode(payload, keys: :atoms!) do
      {:ok, map} -> {:ok, map}
      {:error, err} -> {:error, err}
    end
  end
end
