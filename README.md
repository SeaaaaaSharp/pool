# Description

This is nothing but a port of erlang's poolboy <https://github.com/devinus/poolboy> to elixir done mainly for the purpose of learning
about pooling and becoming more comfortable with erlang's syntax. There were minor tweaks here and there notably the usage of a map instead of a keyword list for the options and the addition of the `checkout_with_args` function.

## Options
The options and their default values remain the same as for poolboy besides the worker_module which gets replaced by a more descriptive `worker_opts` map with a required `worker_module` key and optional `worker_args` key.
## Example

### application.ex

```elixir
defmodule YourApp do
  use Application

  @impl true
  def start(_type, _args) do
    worker_args = [
      host: 'localhost',
      username: 'postgres',
      password: 'postgres',
      database: 'analysis',
      timeout: 4000
    ]

    pool_conf = %{
      name: SomePoolName,
      size: 10,
      max_overflow: 2,
      strategy: :fifo
      worker_opts: %{worker_module: SomeWorkerModule, worker_args: worker_args}
    }

    children = [
      Pool.child_spec(pool_conf)
    ]

    opts = [strategy: :one_for_one, name: YourApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```
## License

Same as poolboy