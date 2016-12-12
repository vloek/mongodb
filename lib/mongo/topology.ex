defmodule Mongo.Topology do
  use GenServer
  alias Mongo.Events.{ServerDescriptionChangedEvent, ServerOpeningEvent,
                      ServerClosedEvent, TopologyDescriptionChangedEvent,
                      TopologyOpeningEvent, TopologyClosedEvent}
  alias Mongo.TopologyDescription
  alias Mongo.ServerDescription
  alias Mongo.Monitor

  @type initial_type :: :unknown | :single | :replica_set_no_primary | :sharded

  @doc ~S"""
  Starts a new topology connection, which handles pooling and server selection
  for replica sets.

  ## Options

  * `:database` - **REQUIRED:** database for authentication and default
  * `:connect_timeout_ms` - maximum timeout for connect
  * `:seeds` - a seed list of hosts (without the "mongodb://" part) within the
    cluster, defaults to `["localhost:27017"]`
  * `:type` - a hint of the topology type, defaults to `:unknown`, see
    `t:initial_type/0` for valid values
  * `:set_name` - the expected replica set name, defaults to `nil`
  * `:heartbeat_frequency_ms` - the interval between server checks, defaults
    to 10 seconds

  ## Error Reasons

  * `:single_topology_multiple_hosts` - a topology of type :single was set but
    multiple hosts were given
  * `:set_name_bad_topology` - a `:set_name` was given but the topology was set
    to something other than `:replica_set_no_primary` or `:single`
  """
  @spec start_link(Keyword.t, Keyword.t) ::
          {:ok, pid} |
          {:error, reason :: atom}
  def start_link(opts, gen_server_opts \\ []) do
    GenServer.start_link(__MODULE__, opts, gen_server_opts)
  end

  def connection_for_address(pid, address) do
    GenServer.call(pid, {:connection, address})
  end

  def topology(pid) do
    GenServer.call(pid, :topology)
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  ## GenServer Callbacks

  # see https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-discovery-and-monitoring.rst#configuration
  @doc false
  def init(opts) do
    seeds = Keyword.get(opts, :seeds,
                        [Keyword.get(opts, :hostname, "localhost") <> ":" <>
                         Keyword.get(opts, :port, "27017")])
    type = Keyword.get(opts, :type, :unknown)
    set_name = Keyword.get(opts, :set_name, nil)
    heartbeat_frequency_ms = Keyword.get(opts, :heartbeat_frequency_ms, 10000)
    local_threshold_ms = Keyword.get(opts, :local_threshold_ms, 15)

    :ok = GenEvent.notify(Mongo.Events, %TopologyOpeningEvent{
      topology_pid: self
    })

    cond do
      type == :single and length(seeds) > 1 ->
        {:stop, :single_topology_multiple_hosts}
      set_name != nil and not type in [:replica_set_no_primary, :single] ->
        {:stop, :set_name_bad_topology}
      true ->
        servers_list = seeds |> Enum.map(fn addr ->
          {addr, ServerDescription.defaults(%{address: addr, type: :unknown})}
        end) |> Enum.into(%{})

        state = %{
          topology: TopologyDescription.defaults(%{
            type: type,
            set_name: set_name,
            servers: servers_list,
            local_threshold_ms: local_threshold_ms
          }),
          seeds: seeds,
          heartbeat_frequency_ms: heartbeat_frequency_ms,
          opts: opts,
          monitors: %{},
          connection_pools: %{}
        } |> reconcile_servers
        {:ok, state}
    end
  end

  def terminate(_reason, _state) do
    :ok = GenEvent.notify(Mongo.Events, %TopologyClosedEvent{
      topology_pid: self
    })
  end

  def handle_call(:topology, _from, state) do
    {:reply, state.topology, state}
  end

  def handle_call({:connection, address}, _from, state) do
    {:reply, Map.fetch(state.connection_pools, address), state}
  end

  # see https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-discovery-and-monitoring.rst#updating-the-topologydescription
  def handle_call({:server_description, server_description}, _from, state) do
    new_state = handle_server_description(state, server_description)
    if state.topology != new_state.topology do
      :ok = GenEvent.notify(Mongo.Events, %TopologyDescriptionChangedEvent{
              topology_pid: self,
              previous_description: state.topology,
              new_description: new_state.topology
      })
      {:reply, :ok, new_state}
    else
      {:reply, :ok, new_state}
    end
  end

  def handle_cast({:force_check, server_address}, state) do
    case Map.fetch(state.monitors, server_address) do
      {:ok, monitor_pid} when is_pid(monitor_pid) ->
        :ok = Monitor.force_check(monitor_pid)
        {:noreply, state}

      :error ->
        # ignore force checks on monitors that don't exist
        {:noreply, state}
    end
  end

  defp handle_server_description(state, server_description) do
    state
    |> get_and_update_in([:topology],
                         &TopologyDescription.update(&1, server_description,
                                                     length(state.seeds)))
    |> process_events
    |> reconcile_servers
  end

  defp process_events({events, state}) do
    Enum.each(events, fn
      {:force_check, _} = message ->
        :ok = GenServer.cast(self, message)
      {previous, next} ->
        if previous != next do
          :ok = GenEvent.notify(Mongo.Events, %ServerDescriptionChangedEvent{
            address: next.address,
            topology_pid: self,
            previous_description: previous,
            new_description: next
          })
        end
      _ ->
        :ok
    end)
    state
  end

  defp reconcile_servers(state) do
    old_addrs = Map.keys(state.monitors)
    new_addrs = Map.keys(state.topology.servers)
    added = new_addrs -- old_addrs
    removed = old_addrs -- new_addrs

    state = Enum.reduce(added, state, fn (address, state) ->
      server_description = state.topology.servers[address]
      connopts = connect_opts_from_address(state.opts, address)
      heartbeat_frequency = state.heartbeat_frequency_ms
      args = [server_description, self, heartbeat_frequency,
              Keyword.put(connopts, :pool, DBConnection.Connection)]

      :ok =
        GenEvent.notify(Mongo.Events, %ServerOpeningEvent{address: address,
                                                          topology_pid: self})

      {:ok, pid} = Monitor.start_link(args)
      {:ok, pool} = DBConnection.start_link(Mongo.Protocol, connopts)
      %{state | monitors: Map.put(state.monitors, address, pid),
        connection_pools: Map.put(state.connection_pools, address, pool)}
    end)
    Enum.reduce(removed, state, fn (address, state) ->
      :ok =
        GenEvent.notify(Mongo.Events, %ServerClosedEvent{address: address,
                                                         topology_pid: self})
      :ok = Monitor.stop(state.monitors[address])
      :ok = GenServer.stop(state.connection_pools[address])
      %{state | monitors: Map.delete(state.monitors, address),
        connection_pools: Map.delete(state.connection_pools, address)}
    end)
  end

  @connect_opts [:database, :pool]
  defp connect_opts_from_address(opts, address) do
    host_opts =
      "mongodb://" <> address
      |> URI.parse
      |> Map.take([:host, :port])
      |> Enum.into([])
      |> rename_key(:host, :hostname)

    Keyword.merge(Keyword.take(opts, @connect_opts), host_opts)
  end

  defp rename_key(map, original_key, new_key) do
    value = Keyword.get(map, original_key)
    map |> Keyword.delete(original_key) |> Keyword.put(new_key, value)
  end
end
