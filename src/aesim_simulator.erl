-module(aesim_simulator).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

-export([run/1]).
-export([print/3]).

%=== MACROS ====================================================================

-define(SIMULATIONS_DIR, "simulations").
-define(REPORT_FILENAME, "report.txt").
-define(DEFAULT_MAX_SIM_TIME,                        "2h").
-define(DEFAULT_MAX_REAL_TIME,                   infinity).
-define(DEFAULT_SCENARIO_MOD,      aesim_scenario_default).
-define(DEFAULT_PROGRESS_INTERVAL,                   "1s").
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
  StartTime = erlang:system_time(millisecond),
  Sim = #{
    config => aesim_config:new(),
    events => aesim_events:new(),
    metrics => aesim_metrics:new(),
    sim_dir => undefined,
    report_file => undefined,
    real_start_time => StartTime,
    time => 0,
    max_real_time => infinity,
    max_sim_time => infinity,
    progress_sim_time => 0,
    progress_sim_interval => 0,
    progress_real_time => StartTime,
    progress_real_interval => 0
  },
  Sim2 = setup_simulation(Opts, Sim),
  {Nodes, Sim3} = nodes_new(Sim2),
  {Scenario, Sim4} = scenario_new(Sim3),
  State = #{nodes => Nodes, scenario => Scenario},
  {State2, Sim5} = scenario_start(State, Sim4),
  try loop(State2, Sim5)
  after
    cleanup_simulation(Sim5)
  end.

-spec print(string(), [term()], sim()) -> ok.
print(Format, Params, #{report_file := undefined}) ->
  io:format(Format, Params);
print(Format, Params, #{report_file := ReportFile}) ->
  file:write(ReportFile, io_lib:format(Format, Params)),
  io:format(Format, Params).

%=== INTERNAL FUNCTIONS ========================================================

setup_simulation(Opts, Sim) ->
  Sim2 = parse_options(Opts, Sim),
  SimSubDir = simulation_dir(Sim2),
  {ok, WorkingDir} = file:get_cwd(),
  SimPath = filename:join(WorkingDir, SimSubDir),
  ReportPath = filename:join(SimPath, ?REPORT_FILENAME),
  ok = filelib:ensure_dir(ReportPath),
  {ok, ReportFile} = file:open(ReportPath, [raw, write]),
  Sim2#{
    max_real_time => cfg_max_real_time(Sim2),
    max_sim_time => cfg_max_sim_time(Sim2),
    sim_dir := SimPath,
    report_file := ReportFile
  }.


cleanup_simulation(#{report_file := undefined}) -> ok;
cleanup_simulation(#{report_file := ReportFile}) ->
  file:close(ReportFile).

-spec loop(state(), sim()) -> ok.
loop(State, Sim) ->
  RealNow = erlang:system_time(millisecond),
  case has_terminated(State, RealNow, Sim) of
    true ->
      scenario_report(State, timeout, Sim);
    false ->
      {State2, Sim2} = progress(State, RealNow, Sim),
      case aesim_events:next(Sim2) of
        {empty, Sim3} ->
          scenario_report(State2, frozen, Sim3);
        {NextTime, EAddr, EName, Params, Sim3} ->
          Sim4 = update_time(NextTime, Sim3),
          {State3, Sim5} = route_event(State2, EAddr, EName, Params, Sim4),
          loop(State3, Sim5)
      end
  end.

progress(State, RealNow, Sim) ->
  #{time := SimTime,
    progress_sim_time := LastSimProgress,
    progress_real_time := LastRealProgress
  } = Sim,
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

has_terminated(State, RealNow, Sim) ->
  #{time := SimTime,
    real_start_time := RealStartTime,
    max_sim_time := MaxSimTime,
    max_real_time := MaxRealTime
  } = Sim,
  check_terminated(RealNow - RealStartTime, MaxRealTime)
    orelse check_terminated(SimTime, MaxSimTime)
    orelse scenario_has_terminated(State, Sim).

check_terminated(_Time, infinity) -> false;
check_terminated(Time, MaxTime) -> Time >= MaxTime.

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

simulation_dir(Sim) ->
  #{real_start_time := T} = Sim,
  Now = {T div 1000000000, (T div 1000) rem 1000000  , (T rem 1000) * 1000},
  {{Y, Mo, D}, {H, Mn, S}} = calendar:now_to_local_time(Now),
  Milli = T rem 1000,
  SubDir = aesim_utils:format("~4.10.0b~2.10.0b~2.10.0b~2.10.0b~2.10.0b~2.10.0b~3.10.0b",
                              [Y, Mo, D, H, Mn, S, Milli]),
  filename:join(?SIMULATIONS_DIR, SubDir).

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
  Mod = cfg_scenario_mod(Sim),
  {Sub, Sim2} = Mod:scenario_new(Sim),
  ?CHECK_SIM(Sim, Sim2),
  {Sub, Sim2}.

scenario_start(State, Sim) ->
  #{scenario := Sub, nodes := Nodes} = State,
  Mod = cfg_scenario_mod(Sim),
  {Sub2, Nodes2, Sim2} = Mod:scenario_start(Sub, Nodes, Sim),
  ?CHECK_SIM(Sim, Sim2),
  {State#{scenario := Sub2, nodes := Nodes2}, Sim2}.

scenario_has_terminated(State, Sim) ->
  #{scenario := Sub, nodes := Nodes} = State,
  Mod = cfg_scenario_mod(Sim),
  Mod:scenario_has_terminated(Sub, Nodes, Sim).

scenario_progress(State, Sim) ->
  #{scenario := Sub, nodes := Nodes} = State,
  Mod = cfg_scenario_mod(Sim),
  {Sub2, Sim2} = Mod:scenario_progress(Sub, Nodes, Sim),
  ?CHECK_SIM(Sim, Sim2),
  {State#{scenario := Sub2}, Sim2}.

scenario_report(State, Reason, Sim) ->
  #{scenario := Sub, nodes := Nodes} = State,
  Mod = cfg_scenario_mod(Sim),
  Mod:scenario_report(Sub, Reason, Nodes, Sim),
  ok.

scenario_handle_event(State, Name, Params, Sim) ->
  #{scenario := Sub, nodes := Nodes} = State,
  Mod = cfg_scenario_mod(Sim),
  case Mod:scenario_handle_event(Sub, Name, Params, Nodes, Sim) of
    ignore -> {State, Sim};
    {Sub2, Nodes2, Sim2} ->
      ?CHECK_SIM(Sim, Sim2),
      {State#{scenario := Sub2, nodes := Nodes2}, Sim2}
  end.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

parse_options(Opts, Sim) ->
  aesim_config:parse(Sim, Opts, [
    {scenario_mod, atom, ?DEFAULT_SCENARIO_MOD},
    {progress_interval, time, ?DEFAULT_PROGRESS_INTERVAL},
    {max_sim_time, time_infinity, ?DEFAULT_MAX_SIM_TIME},
    {max_real_time, time_infinity, ?DEFAULT_MAX_REAL_TIME}
  ], [
    {scenario_mod, parse_options},
    fun aesim_nodes:parse_options/2
  ]).

cfg_max_real_time(Sim) -> aesim_config:get(Sim, max_real_time).

cfg_max_sim_time(Sim) -> aesim_config:get(Sim, max_sim_time).

cfg_scenario_mod(Sim) -> aesim_config:get(Sim, scenario_mod).

cfg_progress_interval(Sim) -> aesim_config:get(Sim, progress_interval).

