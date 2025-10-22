defmodule Example.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      # Inicia automaticamente o pool do Leggy
      {Example, []}
    ]

    opts = [strategy: :one_for_one, name: Example.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
