-module(aesim_scenario_gossip_time).

%% @doc Default simulation scenario.
%%
%% - Starts a cluster of configurable size.
%% - Wait for all nodes to know a configurable percentage of the other nodes.
%% - Start a single node and measure the time for it to get to know a
%%   configurable percentage of the other nodes.
%% - Repeate multiple times and report the min/average/median/max time.
%%
%% Configuration:
%% - `start_period`: The period between new nodes are started; default: 30s.
%% - `max_nodes`: The maximum number of node that get started; default: 150.
%% - `gossip_percent`: The percentage of the other nodes to reach.

-behaviour(aesim_scenario).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% Behaviour esim_scenario callback functions
-export([parse_options/2]).
-export([scenario_new/1]).
-export([scenario_start/3]).
-export([scenario_phase_start/4]).
-export([scenario_phase_stop/4]).
-export([scenario_phase_check/4]).
-export([scenario_handle_event/6]).
-export([scenario_report/4]).

%=== MACROS ====================================================================

-define(DEFAULT_NODE_START_PERIOD,     "30s").
-define(DEFAULT_MAX_NODES,               150).
-define(DEFAULT_GOSSIP_PERCENT,           90).

-define(CHECK_INTERVAL,                  200).
-define(MEASURE_COUNT,                    20).

-define(RESULTS_SPEC, [
  {string, "DESCRIPTION", left, undefined, 36},
  {minimal_time, "MINIMUM", right, undefined, 10},
  {minimal_time, "AVERAGE", right, undefined, 10},
  {minimal_time, "MEDIAN", right, undefined, 10},
  {minimal_time, "MAXIMUM", right, undefined, 10}
]).

%=== TYPES =====================================================================

-type state() :: #{
  event_ref := event_ref() | undefined,
  node_id := id() | undefined,
  measures := [],
  next_phases := [aesim_senario:phase_tag()]
}.

-export_type([state/0]).

%=== BEHAVIOUR aesim_scenario CALLBACK FUNCTIONS ===============================

parse_options(Opts, Sim) ->
  aesim_config:parse(Sim, Opts, [
    {node_start_period, time, ?DEFAULT_NODE_START_PERIOD},
    {max_nodes, integer, ?DEFAULT_MAX_NODES},
    {gossip_percent, integer, ?DEFAULT_GOSSIP_PERCENT}
  ]).

scenario_new(Sim) ->
  State = #{
    event_ref => undefined,
    node_id => undefined,
    measures => [],
    next_phases => [cluster_setup, cluster_gossip
                    | lists:duplicate(?MEASURE_COUNT, node_gossip)]
  },
  Phases = [
    % First phase; starting all the cluster node up to the configured maximum.
    {"Starting cluster nodes",
     cluster_setup, cfg_node_start_period(Sim)},
    % Second phase; waiting for all nodes to know a configurable
    % percentage of the other nodes.
    {"Waiting for nodes to know each others",
     cluster_gossip, ?CHECK_INTERVAL * 60},
    % Third phase; waiting for the last node to know a configured
    % percentage of the other nodes.
    {"Waiting for reference node to know enough of the cluster",
     node_gossip, ?CHECK_INTERVAL}
  ],
  {State, Phases, Sim}.

scenario_start(State, Nodes, Sim) ->
  {Nodes2, Sim2} = aesim_scenario:default_start(Nodes, Sim),
  {State, cluster_setup, Nodes2, Sim2}.

scenario_phase_start(State, Phase, Nodes, Sim) ->
  aesim_scenario:print_phase_start(Phase, Sim),
  phase_start(State, Phase, Nodes, Sim).

scenario_phase_stop(State, Phase, Nodes, Sim) ->
  aesim_scenario:print_phase_stop(Phase, Sim),
  phase_stop(State, Phase, Nodes, Sim).

scenario_phase_check(State, #{tag := PhaseTag}, Nodes, Sim) ->
  case phase_terminated(State, PhaseTag, Nodes, Sim) of
    true -> phase_next(State);
    false -> continue
  end.

scenario_handle_event(State, _, start_node, Count, Nodes, Sim) ->
  do_start_node(State, Count, Nodes, Sim);
scenario_handle_event(_State, _, _EventName, _Params, _Nodes, _Sim) -> ignore.

scenario_report(State, normal, _Nodes, Sim) ->
  #{measures := Measures} = State,
  aesim_simulator:print_title("SCENARIO RESULTS", Sim),
  Desc = aesim_utils:format("Time to know ~b% of the cluster",
                            [cfg_gossip_percent(Sim)]),
  {Min, Avg, Med, Max} = aesim_utils:reduce_metric(Measures),
  Fileds = [Desc, Min, Avg, Med, Max],
  aesim_simulator:print_header(?RESULTS_SPEC, Sim),
  aesim_simulator:print_fields(?RESULTS_SPEC, Fileds, Sim),
  aesim_simulator:print_separator(Sim),
  normal;
scenario_report(_State, Reason, _Nodes, _Sim) -> Reason.

%=== INTERNAL FUNCTIONS ========================================================

phase_next(#{next_phases := []}) -> {stop, normal};
phase_next(#{next_phases := [PhaseTag | _]}) -> {next, PhaseTag}.

phase_started(#{next_phases := [_ | Rest]} = State) ->
  State#{next_phases := Rest}.

phase_start(State, #{tag := cluster_setup}, Nodes, Sim) ->
  %% Start nodes up to the configured maxium
  CurrCount = aesim_nodes:count(Nodes),
  do_start_node(phase_started(State), CurrCount, Nodes, Sim);
phase_start(State, #{tag := cluster_gossip}, Nodes, Sim) ->
  {phase_started(State), Nodes, Sim};
phase_start(State, #{tag := node_gossip}, Nodes, Sim) ->
  %% Start the last node and keep its identifier
  {Nodes2, NodeId, Sim2} = aesim_nodes:start_node(Nodes, Sim),
  {phase_started(State#{node_id := NodeId}), Nodes2, Sim2}.

phase_stop(State, #{tag := cluster_setup}, Nodes, Sim) ->
  {State2, Sim2} = cancel_start_node(State, Sim),
  {State2, Nodes, Sim2};
phase_stop(State, #{tag := cluster_gossip}, Nodes, Sim) ->
  {State, Nodes, Sim};
phase_stop(State, #{tag := node_gossip} = Phase, Nodes, Sim) ->
  #{measures := Measures} = State,
  #{sim_start_time := StartTime, sim_stop_time := StopTime} = Phase,
  Measure = StopTime - StartTime,
  {State#{measures := [Measure | Measures]}, Nodes, Sim}.

phase_terminated(_State, cluster_setup, Nodes, Sim) ->
  aesim_nodes:count(Nodes) >= (cfg_max_nodes(Sim) - ?MEASURE_COUNT);
phase_terminated(_State, cluster_gossip, Nodes, Sim) ->
  nodes_gossip_target_reached(Nodes, Sim);
phase_terminated(State, node_gossip, Nodes, Sim) ->
  #{node_id := NodeId} = State,
  node_gossip_target_reached(NodeId, Nodes, Sim).

nodes_gossip_target_reached(Nodes, Sim) ->
  NodeCount = aesim_nodes:count(Nodes),
  NodesReport = aesim_nodes:report(Nodes, simple, Sim),
  #{nodes := NodeReports} = NodesReport,
  fold_while_true(fun(R) ->
    report_gossip_target_reached(R, NodeCount, Sim)
  end, NodeReports).

node_gossip_target_reached(NodeId, Nodes, Sim) ->
  NodeCount = aesim_nodes:count(Nodes),
  NodeReport = aesim_nodes:node_report(Nodes, NodeId, simple, Sim),
  report_gossip_target_reached(NodeReport, NodeCount, Sim).

report_gossip_target_reached(NodeReport, NodeCount, Sim) ->
  #{pool := PoolReport} = NodeReport,
  #{known_count := KnownCount} = PoolReport,
  (KnownCount * 100 / (NodeCount - 1)) >= cfg_gossip_percent(Sim).

fold_while_true(_Fun, []) -> true;
fold_while_true(Fun, [Data | Rest]) ->
  case Fun(Data) of
    true -> fold_while_true(Fun, Rest);
    false -> false
  end.

%--- EVENTS FUNCTIONS ----------------------------------------------------------

sched_start_node(Count, Sim) ->
  aesim_scenario:post(cfg_node_start_period(Sim), start_node, Count, Sim).

do_start_node(State, Count, Nodes, Sim) ->
  case Count < (cfg_max_nodes(Sim) - ?MEASURE_COUNT) of
    false ->
      {State#{event_ref := undefined}, Nodes, Sim};
    true ->
      {Nodes2, _, Sim2} = aesim_nodes:start_node(Nodes, Sim),
      {Ref, Sim3} = sched_start_node(Count +1, Sim2),
      {State#{event_ref := Ref}, Nodes2, Sim3}
  end.

cancel_start_node(#{event_ref := undefined} = State, Sim) -> {State, Sim};
cancel_start_node(#{event_ref := Ref} = State, Sim) ->
  {State#{event_ref := undefined}, aesim_events:cancel(Ref, Sim)}.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_node_start_period(Sim) -> aesim_config:get(Sim, node_start_period).

cfg_max_nodes(Sim) -> aesim_config:get(Sim, max_nodes).

cfg_gossip_percent(Sim) -> aesim_config:get(Sim, gossip_percent).
