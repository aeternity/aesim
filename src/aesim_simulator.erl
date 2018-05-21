-module(aesim_simulator).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

-export([run/1]).

%=== MACROS ====================================================================

-define(DEFAULT_MAX_TIME,              2 * 60 * 60 * 1000). % 2h
-define(DEFAULT_SCENARIO_MOD,      aesim_scenario_default).
-define(DEFAULT_PROGRESS_INTERVAL,                   1000).
-define(SIM_IMMUTABLES, [config, real_start_time, time, max_time,
                         progress_sim_time, progress_sim_interval,
                         progress_real_time, progress_real_interval]).
-define(CHECK_SIM(OLD, NEW), (?assertEqual(maps:with(?SIM_IMMUTABLES, (OLD)),
                                           maps:with(?SIM_IMMUTABLES, (NEW))))).

%=== TYPES =====================================================================

-type state() :: #{
  nodes := term(),
  scenario := term()
}.

%=== API FUNCTIONS =============================================================

-spec run(map()) -> ok.
run(Opts)->
  lager:info("Starting simulator..."),
  Config = parse_options(Opts),
  StartTime = erlang:system_time(millisecond),
  Sim = #{
    config => Config,
    real_start_time => StartTime,
    time => 0,
    max_time => cfg_max_time(Config),
    progress_sim_time => 0,
    progress_sim_interval => 0,
    progress_real_time => StartTime,
    progress_real_interval => 0,
    events => aesim_events:new()
  },
  {Nodes, Sim2} = nodes_new(Sim),
  {Scenario, Sim3} = scenario_new(Sim2),
  State = #{nodes => Nodes, scenario => Scenario},
  {State2, Sim4} = scenario_start(State, Sim3),
  loop(State2, Sim4).

%=== INTERNAL FUNCTIONS ========================================================

-spec loop(state(), sim()) -> ok.
loop(State, Sim) ->
  case scenario_has_terminated(State, Sim) of
    true ->
      scenario_report(State, timeout, Sim);
    false ->
      {State2, Sim2} = progress(State, Sim),
      case aesim_events:next(Sim2) of
        empty ->
          scenario_report(State2, frozen, Sim2);
        {NextTime, EAddr, EName, Params, Sim3} ->
          Sim4 = update_time(NextTime, Sim3),
          {State3, Sim5} = route_event(State2, EAddr, EName, Params, Sim4),
          loop(State3, Sim5)
      end
  end.

progress(State, Sim) ->
  #{time := SimTime,
    progress_sim_time := LastSimProgress,
    progress_real_time := LastRealProgress
  } = Sim,
  RealNow = erlang:system_time(millisecond),
  case RealNow >= (LastRealProgress + cfg_progress_interval(Sim)) of
    false -> {State, Sim};
    true ->
      Sim2 = Sim#{
        progress_sim_time := SimTime,
        progress_sim_interval := SimTime - LastSimProgress,
        progress_real_time := RealNow,
        progress_real_interval := RealNow - LastRealProgress
      },
      scenario_progress(State, Sim2)
  end.

update_time(NextTime, Sim) ->
  #{time := Time} = Sim,
  Sim#{time := max(Time, NextTime)}.

route_event(State, [scenario], Name, Params, Sim) ->
  scenario_handle_event(State, Name, Params, Sim);
route_event(State, [nodes | Rest], Name, Params, Sim) ->
  nodes_route_event(State, Rest, Name, Params, Sim);
route_event(State, Addr, Name, Params, Sim) ->
  lager:warning("Unexpected simulator event ~p for ~p: ~p", [Name, Addr, Params]),
  {State, Sim}.

%--- NODES FUNCTIONS -----------------------------------------------------------

nodes_new(Sim) ->
  {Sub, Sim2} = aesim_nodes:new(Sim),
  ?CHECK_SIM(Sim, Sim2),
  {Sub, Sim2}.

nodes_route_event(State, EventAddr, Name, Params, Sim) ->
  #{nodes := Nodes} = State,
  {Nodes2, Sim2} = aesim_nodes:route_event(Nodes, EventAddr, Name, Params, Sim),
  ?CHECK_SIM(Sim, Sim2),
  {State#{nodes := Nodes2}, Sim2}.

%--- SCENARIO CALLBACK FUNCTIONS -----------------------------------------------

scenario_new(Sim) ->
  % Mod = cfg_scenario_mod(Sim),
  % {Sub, Sim2} = Mod:scenario_new(Sim),
  {Sub, Sim2} = aesim_scenario_default:scenario_new(Sim),
  ?CHECK_SIM(Sim, Sim2),
  {Sub, Sim2}.

scenario_start(State, Sim) ->
  #{scenario := Sub, nodes := Nodes} = State,
  % Mod = cfg_scenario_mod(Sim),
  % {Sub2, Nodes2, Sim2} = Mod:scenario_start(Sub, Nodes, Sim),
  {Sub2, Nodes2, Sim2} = aesim_scenario_default:scenario_start(Sub, Nodes, Sim),
  ?CHECK_SIM(Sim, Sim2),
  {State#{scenario := Sub2, nodes := Nodes2}, Sim2}.

scenario_has_terminated(State, Sim) ->
  #{scenario := Sub, nodes := Nodes} = State,
  % Mod = cfg_scenario_mod(Sim),
  % Mod:scenario_has_terminated(Sub, Nodes, Sim).
  aesim_scenario_default:scenario_has_terminated(Sub, Nodes, Sim).

scenario_progress(State, Sim) ->
  #{scenario := Sub, nodes := Nodes} = State,
  % Mod = cfg_scenario_mod(Sim),
  % {Sub2, Sim2} = Mod:scenario_progress(Sub, Nodes, Sim),
  {Sub2, Sim2} = aesim_scenario_default:scenario_progress(Sub, Nodes, Sim),
  ?CHECK_SIM(Sim, Sim2),
  {State#{scenario := Sub2}, Sim2}.

scenario_report(State, Reason, Sim) ->
  #{scenario := Sub, nodes := Nodes} = State,
  % Mod = cfg_scenario_mod(Sim),
  %Mod:scenario_report(Sub, Reason, Nodes, Sim),
  aesim_scenario_default:scenario_report(Sub, Reason, Nodes, Sim),
  ok.

scenario_handle_event(State, Name, Params, Sim) ->
  #{scenario := Sub, nodes := Nodes} = State,
  % Mod = cfg_scenario_mod(Sim),
  % case Mod:scenario_handle_event(Sub, Name, Params, Nodes, Sim) of
  case aesim_scenario_default:scenario_handle_event(Sub, Name, Params, Nodes, Sim) of
    ignore -> {State, Sim};
    {Sub2, Nodes2, Sim2} ->
      ?CHECK_SIM(Sim, Sim2),
      {State#{scenario := Sub2, nodes := Nodes2}, Sim2}
  end.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

parse_options(Opts) ->
  Config = aesim_config:parse(#{}, Opts, [
    {scenario_mod, atom, ?DEFAULT_SCENARIO_MOD},
    {progress_interval, integer, ?DEFAULT_PROGRESS_INTERVAL},
    {max_time, time, ?DEFAULT_MAX_TIME}
  ]),
  Config2 = aesim_nodes:parse_options(Config, Opts),
  ScenarioMod = cfg_scenario_mod(Config2),
  ScenarioMod:parse_options(Config2, Opts).

cfg_max_time(Config) -> aesim_config:get(Config, max_time).

cfg_scenario_mod(Config) -> aesim_config:get(Config, scenario_mod).

cfg_progress_interval(Config) -> aesim_config:get(Config, progress_interval).

