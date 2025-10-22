defmodule Example do
  use Leggy,
    host: "localhost",
    username: "guest",
    password: "guest",
    pool_size: 4

  defmodule Schemas.RabbitSchema do
    use Leggy.Schema

    schema "banana_exchange", "banana_queue" do
      field(:user, :string)
      field(:ttl, :integer)
      field(:valid?, :boolean)
      field(:requested_at, :datetime)
    end
  end

  alias Schemas.RabbitSchema

  def start_pool do
    {:ok, _pid} = start_link()
  end

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
        IO.inspect(struct, label: "✅ Received message")
        :ok

      {:error, reason} ->
        IO.inspect(reason, label: "❌ Error")
        :error
    end
  end
end
