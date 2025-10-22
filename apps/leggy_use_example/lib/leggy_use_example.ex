defmodule LeggyUseExample do
  use Leggy,
    host: "localhost",
    username: "guest",
    password: "guest",
    pool_size: 4

  alias LeggyUseExample.Schemas.RabbitSchema

  def prepare, do: prepare(RabbitSchema)

  def producer do
    {:ok, msg} =
      cast(RabbitSchema, %{
        user: "r2d2",
        ttl: 5,
        valid?: true,
        requested_at: DateTime.utc_now()
      })

    publish(msg)
  end

  def consumer do
    case get(RabbitSchema) do
      {:ok, struct} ->
        IO.inspect(struct, label: "Received struct")
        :ok

      {:error, reason} ->
        IO.puts("Failed to get message: #{inspect(reason)}")
        :error
    end
  end
end
