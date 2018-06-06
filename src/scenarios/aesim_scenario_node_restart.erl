-module(aesim_scenario_node_restart).

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
-export([scenario_phase_check/4]).
-export([scenario_report/4]).
-export([scenario_handle_event/6]).

%=== MACROS ====================================================================

-define(DEFAULT_NODE_START_PERIOD,     "30s").
-define(DEFAULT_MAX_NODES,               150).
-define(DEFAULT_NODE_RESTART_PERIOD,   "1m").

%=== BEHAVIOUR aesim_scenario CALLBACK FUNCTIONS ===============================

parse_options(Opts, Sim) ->
  aesim_config:parse(Sim, Opts, [
    {node_start_period, time, ?DEFAULT_NODE_START_PERIOD},
    {node_restart_period, time, ?DEFAULT_NODE_RESTART_PERIOD},
    {max_nodes, integer, ?DEFAULT_MAX_NODES}
  ]).

scenario_new(Sim) ->
  Phases = [
    % First phase; starting all the cluster node up to the configured maximum.
    {"Starting cluster nodes",
     cluster_setup, cfg_node_start_period(Sim)},
    % Second phase; Keep restarting random nodes.
    {"Restaring random nodes",
     node_restart, infinity}
  ],
  {#{}, Phases, Sim}.

scenario_start(State, Nodes, Sim) ->
  {Nodes2, Sim2} = aesim_scenario:default_start(Nodes, Sim),
  {State, cluster_setup, Nodes2, Sim2}.

scenario_phase_start(State, #{tag := cluster_setup} = Phase, Nodes, Sim) ->
  aesim_scenario:print_phase_start(Phase, Sim),
  CurrCount = aesim_nodes:count(Nodes),
  do_start_node(State, CurrCount, Nodes, Sim);
scenario_phase_start(State, #{tag := node_restart} = Phase, Nodes, Sim) ->
  aesim_scenario:print_phase_start(Phase, Sim),
  do_restart_node(State, Nodes, Sim).

scenario_phase_check(_State, #{tag := cluster_setup}, Nodes, Sim) ->
  case aesim_nodes:count(Nodes) >= cfg_max_nodes(Sim) of
    true -> {next, node_restart};
    false -> continue
  end;
scenario_phase_check(_State, _Phase, _Nodes, _Sim) -> continue.

scenario_report(_State, Reason, Nodes, Sim) ->
  aesim_scenario:default_report(Reason, Nodes, Sim),
  aesim_simulator:print_separator(Sim),
  % Timeing out is not an error in this scenario
  case lists:member(Reason, [sim_timeout, real_timeout]) of
    true -> normal;
    false -> Reason
  end.

scenario_handle_event(State, _, start_node, Count, Nodes, Sim) ->
  do_start_node(State, Count, Nodes, Sim);
scenario_handle_event(State, _, restart_node, [], Nodes, Sim) ->
  do_restart_node(State, Nodes, Sim);
scenario_handle_event(_State, _, _EventName, _Params, _Nodes, _Sim) -> ignore.

%=== INTERNAL FUNCTIONS ========================================================

%--- EVENTS FUNCTIONS ----------------------------------------------------------

sched_start_node(Count, Sim) ->
  aesim_scenario:post(cfg_node_start_period(Sim), start_node, Count, Sim).

sched_restart_node(Sim) ->
  aesim_scenario:post(cfg_node_restart_period(Sim), restart_node, [], Sim).

do_start_node(State, Count, Nodes, Sim) ->
  case Count < cfg_max_nodes(Sim) of
    false -> ignore;
    true ->
      {Nodes2, _, Sim2} = aesim_nodes:start_node(Nodes, Sim),
      {_, Sim3} = sched_start_node(Count + 1, Sim2),
      {State, Nodes2, Sim3}
  end.

do_restart_node(State, Nodes, Sim) ->
  Total = aesim_nodes:count(Nodes),
  RandId = aesim_utils:rand(Total) + 1,
  {Nodes2, Sim2} = aesim_nodes:restart_node(Nodes, RandId, Sim),
  {_, Sim3} = sched_restart_node(Sim2),
  {State, Nodes2, Sim3}.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_node_start_period(Sim) -> aesim_config:get(Sim, node_start_period).

cfg_node_restart_period(Sim) -> aesim_config:get(Sim, node_restart_period).

cfg_max_nodes(Sim) -> aesim_config:get(Sim, max_nodes).
