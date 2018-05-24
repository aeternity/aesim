-module(aesim_scenario_default).

%% @doc Default simulation scenario.
%%
%% It only bootstrap the cluster and periodically start a new node up to a
%% configurable limite. The simulation is topped when the configurable
%% time limite is reached.
%%
%% Configuration:
%% - `start_period`: The period between new nodes are started; default: 30s.
%% - `max_nodes`: The maximum number of node that get started; default: 150.
%%
%% It reports some basic node metrics.

-behaviour(aesim_scenario).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% Behaviour esim_scenario callback functions
-export([parse_options/2]).
-export([scenario_new/1]).
-export([scenario_start/3]).
-export([scenario_has_terminated/3]).
-export([scenario_progress/3]).
-export([scenario_report/4]).
-export([scenario_handle_event/5]).

%=== MACROS ====================================================================

-define(DEFAULT_NODE_START_PERIOD,     "30s").
-define(DEFAULT_MAX_NODES,               150).

%=== BEHAVIOUR aesim_scenario CALLBACK FUNCTIONS ===============================

parse_options(Opts, Sim) ->
  aesim_config:parse(Sim, Opts, [
    {node_start_period, time, ?DEFAULT_NODE_START_PERIOD},
    {max_nodes, integer, ?DEFAULT_MAX_NODES}
  ]).

scenario_new(Sim) -> {#{}, Sim}.

scenario_start(State, Nodes, Sim) ->
  {Nodes2, Sim2} = aesim_scenario:default_start(Nodes, Sim),
  CurrCount = aesim_nodes:count(Nodes2),
  {_, Sim3} = sched_start_node(CurrCount, Sim2),
  {State, Nodes2, Sim3}.

scenario_has_terminated(_State, _Nodes, _Sim) -> false.

scenario_progress(State, Nodes, Sim) ->
  aesim_scenario:default_progress(Nodes, Sim),
  {State, Sim}.

scenario_report(_State, Reason, Nodes, Sim) ->
  aesim_scenario:default_report(Reason, Nodes, Sim),
  aesim_scenario:print_separator(Sim).

scenario_handle_event(State, start_node, Count, Nodes, Sim) ->
  do_start_node(State, Count, Nodes, Sim);
scenario_handle_event(_State, _EventName, _Params, _Nodes, _Sim) -> ignore.

%=== INTERNAL FUNCTIONS ========================================================

%--- EVENTS FUNCTIONS ----------------------------------------------------------

sched_start_node(Count, Sim) ->
  aesim_scenario:post(cfg_node_start_period(Sim), start_node, Count, Sim).

do_start_node(State, Count, Nodes, Sim) ->
  case Count < cfg_max_nodes(Sim) of
    false -> ignore;
    true ->
      {Nodes2, Sim2} = aesim_nodes:start_node(Nodes, Sim),
      {_, Sim3} = sched_start_node(Count +1, Sim2),
      {State, Nodes2, Sim3}
  end.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_node_start_period(Sim) -> aesim_config:get(Sim, node_start_period).

cfg_max_nodes(Sim) -> aesim_config:get(Sim, max_nodes).
