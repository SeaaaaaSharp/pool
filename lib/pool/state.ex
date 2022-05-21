defmodule Pool.State do
  @type t :: %__MODULE__{
          supervisor: pid(),
          workers: :queue.queue(),
          waiting: :queue.queue(),
          monitors: :ets.tid(),
          worker_opts: %{
            worker_module: module(),
            worker_args: term()
          },
          strategy: :lifo | :fifo,
          size: non_neg_integer(),
          max_overflow: non_neg_integer(),
          overflow: non_neg_integer()
        }

  defguard is_non_neg_integer(value) when is_integer(value) and value > -1

  defstruct [
    :supervisor,
    :workers,
    :waiting,
    :monitors,
    :overflow,
    :worker_opts,
    strategy: :lifo,
    size: 5,
    max_overflow: 10
  ]

  def new!(opts) do
    __MODULE__
    |> struct(opts)
    |> validate_options()
  end

  defp validate_options(%{strategy: strategy, size: size, max_overflow: max_overflow} = state)
       when (strategy == :lifo or strategy == :fifo) and
              is_non_neg_integer(size) and
              is_non_neg_integer(max_overflow) do
    state
  end
end
