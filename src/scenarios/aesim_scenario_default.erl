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

-define(DEFAULT_NODE_START_PERIOD, 30 * 1000).
-define(DEFAULT_MAX_NODES,               150).
-define(PROGRESS_SPECS, [
  {integer, "PROGRESS", right, "%", 8},
  {time, "REAL-TIME", right, undefined, 13},
  {time, "SIM-TIME", right, undefined, 13},
  {speed, "CURR-SPEED", right, "x", 10},
  {speed, "GLOB-SPEED", right, "x", 10},
  {integer, "NODES", right, undefined, 5},
  {integer, "CONNS", right, undefined, 7},
  {integer, "EVENTS", right, undefined, 7}
]).
-define(REPORT_SPECS, [
  {string, "DESCRIPTION", left, undefined, 30},
  {integer, "MINIMUM", right, undefined, 7},
  {integer, "AVERAGE", right, undefined, 7},
  {integer, "MEDIAN", right, undefined, 7},
  {integer, "MAXIMUM", right, undefined, 7}
]).

%=== BEHAVIOUR aesim_scenario CALLBACK FUNCTIONS ===============================

parse_options(Config, Opts) ->
  aesim_config:parse(Config, Opts, [
    {node_start_period, time, ?DEFAULT_NODE_START_PERIOD},
    {max_nodes, integer, ?DEFAULT_MAX_NODES}
  ]).

scenario_new(Sim) -> {#{}, Sim}.

scenario_start(State, Nodes, Sim) ->
  {Nodes2, Sim2} = aesim_nodes:bootstrap(Nodes, Sim),
  CurrCount = aesim_nodes:count(Nodes2),
  {_, Sim3} = sched_start_node(CurrCount, Sim2),
  aesim_scenario:print_title("CONFIGURATION"),
  aesim_scenario:print_config(Sim3),
  aesim_scenario:print_title("SIMULATION"),
  aesim_scenario:print_header(?PROGRESS_SPECS),
  {State, Nodes2, Sim3}.

scenario_has_terminated(_State, _Nodes, Sim) ->
  #{time := SimTime, max_time := MaxTime} = Sim,
  SimTime >= MaxTime.

scenario_progress(State, Nodes, Sim) ->
  EventCount = aesim_events:size(Sim),
  #{progress := Progress,
    real_time := RealTime,
    sim_time := SimTime,
    current_speed := CurrSpeed,
    global_speed := GlobSpeed
  } = aesim_scenario:calculate_progress(Sim),
  #{node_count := NodeCount,
    connection_count := ConnCount
  } = aesim_nodes:report(Nodes, simple, Sim),
  Fields = [Progress, RealTime, SimTime, CurrSpeed, GlobSpeed,
            NodeCount, ConnCount, EventCount],
  aesim_scenario:print_fields(?PROGRESS_SPECS, Fields),
  {State, Sim}.

scenario_report(_Reason,  _State, Nodes, Sim) ->
  aesim_scenario:print_title("EVENTS STATUS"),
  aesim_events:print_summary(Sim),
  aesim_scenario:print_title("NODES METRICS"),
  aesim_scenario:print_header(?REPORT_SPECS),
  lists:foreach(fun({Desc, {Min, Avg, Med, Max}}) ->
    Fields = [Desc, Min, Avg, Med, Max],
    aesim_scenario:print_fields(?REPORT_SPECS, Fields)
  end, aesim_scenario:node_metrics(Nodes, Sim)),
  aesim_scenario:print_separator(),
  ok.

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

cfg_node_start_period(Config) -> aesim_config:get(Config, node_start_period).

cfg_max_nodes(Config) -> aesim_config:get(Config, max_nodes).
