defmodule ExampleRPC.LeggyRepo do
    use Leggy,
      host: "localhost",
      username: "guest",
      password: "guest",
      pool_size: 4
end
