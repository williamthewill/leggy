
<div align="center">

# 🐇 Leggy  
**Mensageria simples e segura com RabbitMQ em Elixir**

[![Hex.pm](https://img.shields.io/hexpm/v/leggy.svg)](https://hex.pm/packages/leggy)
[![Docs](https://img.shields.io/badge/docs-hexdocs.pm-blue)](https://hexdocs.pm/leggy)
[![License](https://img.shields.io/github/license/infleet/leggy)](LICENSE)

</div>

---

## 💡 Visão geral

O **Leggy** simplifica o uso do RabbitMQ no Elixir, criando **schemas tipados** para as mensagens
e uma API elegante para publicação e consumo.

- ✅ Contratos de mensagens (via `Leggy.Schema`)
- 🔒 Tipagem e validação automática
- 🧩 Pool de canais resiliente
- 📬 Publicação e leitura simplificada
- ⚙️ Configuração declarativa

---

## 🚀 Instalação

Adicione ao `mix.exs`:

```elixir
def deps do
  [
    {:leggy, "~> 0.1.0"},
    {:amqp, "~> 3.3"},
    {:jason, "~> 1.4"}
  ]
end
```

---

## 🧱 Exemplo de uso

```elixir
defmodule MyApp.RabbitRepo do
  use Leggy, host: "localhost", username: "guest", password: "guest", pool_size: 4
end

defmodule MyApp.Schemas.EmailChangeMessage do
  use Leggy.Schema

  schema "exchange_name", "queue_name" do
    field :user, :string
    field :ttl, :integer
    field :valid?, :boolean
    field :requested_at, :datetime
  end
end
```

### Preparar exchange e fila

```elixir
MyApp.RabbitRepo.prepare(MyApp.Schemas.EmailChangeMessage)
```

### Publicar uma mensagem

```elixir
{:ok, msg} =
  MyApp.RabbitRepo.cast(MyApp.Schemas.EmailChangeMessage, %{
    user: "r2d2",
    ttl: 5,
    valid?: true,
    requested_at: DateTime.utc_now()
  })

MyApp.RabbitRepo.publish(msg)
```

### Consumir uma mensagem

```elixir
MyApp.RabbitRepo.get(MyApp.Schemas.EmailChangeMessage)
# => {:ok, %MyApp.Schemas.EmailChangeMessage{...}}
```

---

## 🧠 Estrutura interna

| Módulo | Função |
|:--|:--|
| `Leggy` | Interface principal e macros de configuração |
| `Leggy.Schema` | Define schemas de mensagens |
| `Leggy.ChannelPool` | Gerencia canais AMQP com reconexão |
| `Leggy.Validator` | Faz o cast e validação de tipos |
| `Leggy.Codec` | Codifica/decodifica mensagens JSON |

---

## 🧰 Desenvolvimento

Execute o RabbitMQ localmente:

```bash
docker run -d --rm --name rabbit -p 5672:5672 rabbitmq:3-management
```

Rode os testes:

```bash
mix test
```

Gere a documentação:

```bash
mix docs
```

---

## 📄 Licença

MIT © [Infleet OpenSource](https://github.com/infleet)
