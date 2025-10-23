defmodule ExampleRPC.Consumer do
  def handle_rpc(%ExampleRPC.Schemas.RabbitSchema{user: user}) do
    IO.puts("Mensagem processada: #{user}")
  end
end
