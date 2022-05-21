defmodule Pool.Sup do
  use DynamicSupervisor

  def start_link do
    DynamicSupervisor.start_link(__MODULE__, [])
  end

  def init(_init_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_child(supervisor, worker_module, worker_args) do
    worker_spec = %{
      id: make_ref(),
      start: {worker_module, :start_link, [worker_args]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(supervisor, worker_spec)
  end

  def terminate_child(supervisor, worker_pid) do
    DynamicSupervisor.terminate_child(supervisor, worker_pid)
  end
end
