defmodule ExampleRPC.Application do
  use Application

  def start(_type, _args) do
    children = [
      {ExampleRPC.LeggyRepo, []},
      {Leggy.Consumer, [ExampleRPC.LeggyRepo, ExampleRPC.Schemas.RabbitSchema, &ExampleRPC.Consumer.handle_rpc/1]}
    ]

    opts = [strategy: :one_for_one, name: ExampleRPC.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
