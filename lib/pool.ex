defmodule Pool do
  use GenServer
  require Logger
  alias Pool.State
  @timeout 5_000

  def child_spec(opts) when is_map(opts) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(opts :: map()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Map.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status(pool_name :: GenServer.server()) :: :full | :overflow | :ready
  def status(pool_name) do
    GenServer.call(pool_name, :status)
  end

  @spec stop(pool_name :: GenServer.server()) :: :ok
  def stop(pool_name, reason \\ :normal, timeout \\ @timeout) do
    GenServer.stop(pool_name, reason, timeout)
  end

  @spec checkout(
          pool_name :: GenServer.server(),
          block? :: boolean(),
          timeout :: timeout()
        ) :: pid() | :full
  def checkout(pool_name, block? \\ false, timeout \\ @timeout) do
    checkout_ref = make_ref()

    try do
      GenServer.call(pool_name, {:checkout, checkout_ref, block?}, timeout)
    catch
      _, _ ->
        GenServer.cast(pool_name, {:cancel_waiting, checkout_ref})
        # this triggers the DOWN signal
        raise "Timed out while checkin out from pool #{inspect(pool_name)}"
    end
  end

  def checkout_with_args(pool_name, args, timeout \\ @timeout) do
    GenServer.call(pool_name, {:checkout_with_args, make_ref(), args}, timeout)
  end

  @spec checkin(pool_name :: GenServer.server(), worker_pid :: pid()) :: :ok
  def checkin(pool_name, worker_pid) do
    GenServer.cast(pool_name, {:checkin, worker_pid})
  end

  @spec transaction(
          pool_name :: GenServer.server(),
          fun_to_run :: (worker :: pid -> any()),
          timeout :: timeout()
        ) :: any()
  def transaction(pool_name, fun_to_run, timeout \\ @timeout) do
    worker = checkout(pool_name, true, timeout)

    try do
      fun_to_run.(worker)
    after
      checkin(pool_name, worker)
    end
  end

  defp get_state_name(%{overflow: a, max_overflow: a}) do
    :full
  end

  defp get_state_name(%{overflow: overflow} = state) when overflow < 1 do
    # overflow hasnt been reached
    %{max_overflow: max_overflow, workers: workers} = state

    case :queue.len(workers) == 0 do
      # all workers are being used and cant overflow
      true when max_overflow < 1 -> :full
      # all workers being used and can still overflow
      true -> :overflow
      # there are workers available
      _ -> :ready
    end
  end

  # can still overflow
  defp get_state_name(_) do
    :overflow
  end

  defp add_workers(supervisor, size, worker_opts) do
    if size < 1 do
      :queue.new()
    else
      for _ <- 1..size, reduce: :queue.new() do
        queue -> :queue.in(new_worker(supervisor, worker_opts), queue)
      end
    end
  end

  defp new_worker(supervisor, %{worker_module: worker_module, worker_args: worker_args}) do
    {:ok, worker_pid} = Pool.Sup.start_child(supervisor, worker_module, worker_args)
    Process.link(worker_pid)
    worker_pid
  end

  defp get_worker_with_strategy(workers, :lifo), do: :queue.out_r(workers)
  defp get_worker_with_strategy(workers, :fifo), do: :queue.out(workers)

  defp handle_checkin(worker_pid, state) do
    %{
      supervisor: supervisor,
      waiting: waiting,
      monitors: monitors,
      overflow: overflow,
      workers: workers
    } = state

    case :queue.out(waiting) do
      {{:value, {waiting_client, checkout_ref, monitor_ref}}, rest} ->
        # replies to a waiting process with the checked
        # in worker and removes it from the waiting queue
        GenServer.reply(waiting_client, worker_pid)
        :ets.insert(monitors, {worker_pid, checkout_ref, monitor_ref})
        %{state | waiting: rest}

      {:empty, empty_q} when overflow > 0 ->
        # no process waiting and worker is the result of an overflow
        # so it wont be checked in
        # need to unlink and terminate the worker
        Process.unlink(worker_pid)
        Pool.Sup.terminate_child(supervisor, worker_pid)
        %{state | waiting: empty_q, overflow: overflow - 1}

      {:empty, empty_q} ->
        # check in worker and set overflow back to 0
        workers = :queue.in(worker_pid, workers)
        %{state | workers: workers, waiting: empty_q, overflow: 0}
    end
  end

  defp handle_worker_exit(worker_pid, state) do
    %{
      supervisor: supervisor,
      waiting: waiting,
      monitors: monitors,
      worker_opts: worker_opts,
      overflow: overflow,
      workers: workers
    } = state

    case :queue.out(waiting) do
      {{:value, {client_pid, checkout_ref, monitor_ref}}, waiting} ->
        worker = new_worker(supervisor, worker_opts)
        GenServer.reply(client_pid, worker)
        :ets.insert(monitors, {worker, checkout_ref, monitor_ref})
        %{state | waiting: waiting}

      {:empty, _empty} when overflow > 0 ->
        %{state | overflow: overflow - 1}

      {:empty, _} ->
        workers = remove_worker(worker_pid, workers)
        workers = :queue.in(new_worker(supervisor, worker_opts), workers)
        %{state | workers: workers, waiting: waiting}
    end
  end

  defp remove_worker(worker_pid, workers) do
    :queue.filter(fn pid -> pid != worker_pid end, workers)
  end

  defp get_worker_opts(%{worker_module: _, worker_args: _} = worker_opts) do
    worker_opts
  end

  defp get_worker_opts(%{worker_module: worker_module}) do
    %{worker_module: worker_module, worker_args: nil}
  end

  defp get_worker_opts(unknown_value) do
    raise ArgumentError,
          "Expected worker options with required key `:worker_module`, got : #{inspect(unknown_value)}"
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = State.new!(opts)

    {:ok, supervisor} = Pool.Sup.start_link()

    monitors = :ets.new(:monitors, [:private])

    # for blocking requests
    waiting = :queue.new()

    {size, opts} = Map.pop(opts, :size)

    worker_opts = get_worker_opts(opts[:worker_opts])

    {:module, _worker_module} = Code.ensure_loaded(worker_opts.worker_module)

    unless Kernel.function_exported?(worker_opts.worker_module, :start_link, 1) do
      raise "Worker module #{inspect(worker_opts.worker_module)} does not export function start_link/1"
    end

    workers = add_workers(supervisor, size, worker_opts)

    {:ok,
     %{
       state
       | supervisor: supervisor,
         monitors: monitors,
         waiting: waiting,
         workers: workers,
         overflow: 0
     }}
  end

  @impl true
  def handle_cast(
        {:cancel_waiting, checkout_ref},
        %{monitors: monitors, waiting: waiting} = state
      ) do
    case :ets.match(monitors, {:"$1", checkout_ref, :"$2"}) do
      # To avoid some race condition (?) where we insert the client pid during
      # a blocking checkout and try to respond but client has timed out
      [[worker_pid, monitor_ref]] ->
        Process.demonitor(monitor_ref, [:flush])
        :ets.delete(monitors, worker_pid)
        {:noreply, handle_checkin(worker_pid, state)}

      [] ->
        cancel_fun = fn
          {_, ^checkout_ref, monitor_ref} ->
            Process.demonitor(monitor_ref, [:flush])
            false

          _ ->
            true
        end

        # removes the waiting process from
        # the queue in case it has been put in
        waiting = :queue.filter(cancel_fun, waiting)

        {:noreply, %{state | waiting: waiting}}
    end
  end

  @impl true
  def handle_cast({:checkin, worker_pid}, %{monitors: monitors} = state) do
    case :ets.lookup(monitors, worker_pid) do
      [{_, _, monitor_ref}] ->
        # demonitors the previously monitored client
        Process.demonitor(monitor_ref)
        # and deletes the record from the ets table
        :ets.delete(monitors, worker_pid)
        new_state = handle_checkin(worker_pid, state)
        {:noreply, new_state}

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(
        {:checkout_with_args, checkout_ref, args},
        {client_pid, _ref},
        %{
          monitors: monitors,
          max_overflow: max_overflow,
          overflow: overflow,
          supervisor: supervisor,
          worker_opts: worker_opts
        } = state
      ) do
    cond do
      max_overflow > 0 and overflow < max_overflow ->
        worker_pid = new_worker(supervisor, %{worker_opts | worker_args: args})
        monitor_ref = Process.monitor(client_pid)
        :ets.insert(monitors, {worker_pid, checkout_ref, monitor_ref})

        {:reply, {:ok, worker_pid}, %{state | overflow: overflow + 1}}

      max_overflow > 0 ->
        {:reply, {:error, :full}, state}

      true ->
        {:reply, {:error, :invalid_max_overflow_value}, state}
    end
  end

  @impl true
  def handle_call({:checkout, checkout_ref, block?}, {from_pid, _} = from, state) do
    %{
      supervisor: supervisor,
      workers: workers,
      monitors: monitors,
      overflow: overflow,
      max_overflow: max_overflow,
      strategy: strategy,
      waiting: waiting,
      worker_opts: worker_opts
    } = state

    case get_worker_with_strategy(workers, strategy) do
      # worker available
      {{:value, worker_pid}, rest} ->
        # Monitors the process that checked out a worker
        monitor_ref = Process.monitor(from_pid)
        # Adds it to the monitored processes ets table
        :ets.insert(monitors, {worker_pid, checkout_ref, monitor_ref})
        # replies with the worker pid
        {:reply, worker_pid, %{state | workers: rest}}

      # maximum overflow size hasnt been reached yet
      {:empty, _left} when max_overflow > 0 and overflow < max_overflow ->
        # starts a new worker
        worker_pid = new_worker(supervisor, worker_opts)
        # monitors the process that checks it out
        monitor_ref = Process.monitor(from_pid)
        :ets.insert(monitors, {worker_pid, checkout_ref, monitor_ref})
        # increments overflow to keep track of how many workers are checked out
        {:reply, worker_pid, %{state | overflow: overflow + 1}}

      # empty queue
      _ ->
        if block? do
          # we monitor the client that wants to
          # wait for a worker to be checked in
          monitor_ref = Process.monitor(from_pid)
          # and add him to the waiting queue
          waiting = :queue.in({from, checkout_ref, monitor_ref}, waiting)
          {:noreply, %{state | waiting: waiting}}
        else
          {:reply, :full, state}
        end
    end
  end

  @impl true
  def handle_call(:status, _, state) do
    %{workers: workers, monitors: monitors, overflow: overflow} = state

    state_name = get_state_name(state)

    number_of_workers = :queue.len(workers)

    monitors_size = :ets.info(monitors, :size)

    {:reply, {state_name, number_of_workers, overflow, monitors_size}, state}
  end

  @impl true
  def handle_call(:stop, _, state) do
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor_ref, _, _client_pid, _reason},
        %{monitors: monitors, waiting: waiting} = state
      ) do
    case :ets.match(monitors, {:"$1", :_, monitor_ref}) do
      [[worker_pid]] ->
        :ets.delete(monitors, worker_pid)
        {:noreply, handle_checkin(worker_pid, state)}

      _ ->
        waiting =
          :queue.filter(fn {_client_pid, _checkout_ref, mref} -> mref != monitor_ref end, waiting)

        {:noreply, %{state | waiting: waiting}}
    end
  end

  @impl true
  def handle_info({:EXIT, worker_pid, _reason}, state) do
    %{supervisor: supervisor, monitors: monitors, workers: workers, worker_opts: worker_opts} =
      state

    case :ets.lookup(monitors, worker_pid) do
      [{_worker_pid, _checkout_ref, monitor_ref}] ->
        Process.demonitor(monitor_ref)
        :ets.delete(monitors, worker_pid)
        {:noreply, handle_worker_exit(worker_pid, state)}

      _ ->
        if :queue.member(worker_pid, workers) do
          workers = remove_worker(worker_pid, workers)
          new_worker = new_worker(supervisor, worker_opts)
          {:noreply, %{state | workers: :queue.in(new_worker, workers)}}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info(message, state) do
    IO.inspect(message, label: :unknown_message)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{workers: workers, supervisor: supervisor}) do
    :queue.fold(fn worker_pid, _ -> Process.unlink(worker_pid) end, nil, workers)
    Process.exit(supervisor, :shutdown)
    :ok
  end
end
