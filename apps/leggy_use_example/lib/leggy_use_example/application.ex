defmodule LeggyUseExample.Application do
  use Application

  def start(_type, _args) do
    children = [
      # inicia automaticamente o pool do Leggy
      {LeggyUseExample, []}
    ]

    opts = [strategy: :one_for_one, name: LeggyUseExample.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
