  defmodule Example.Schemas.RabbitSchema do
    use Leggy.Schema

    schema "banana_exchange", "banana_queue" do
      field(:user, :string)
      field(:ttl, :integer)
      field(:valid?, :boolean)
      field(:requested_at, :datetime)
    end
  end
