-module(aesim_simulator).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

-export([run/1]).
-export([print/3]).
-export([print_separator/1]).
-export([print_title/2]).
-export([print_header/2]).
-export([print_fields/3]).

%=== MACROS ====================================================================

-define(LINE_LENGTH, 80).
-define(PREFIX_SIZE, 3).
-define(HEADER_CHAR, $#).
-define(NO_SPACE_CHAR, $*).
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

-type print_type() :: string | integer | time | speed.
-type print_just() :: left | right.
-type print_spec() :: {print_type(), string(), print_just(), string() | undefined, pos_integer()}.
-type print_specs() :: [print_spec()].

-type state() :: #{
  metrics_interval := pos_integer(),
  nodes := term(),
  scenario := term()
}.

%=== API FUNCTIONS =============================================================

-spec run(map()) -> termination_reason().
run(Opts)->
  lager:info("Starting simulator..."),
  Sim = #{
    config => aesim_config:new(),
    events => aesim_events:new(),
    metrics => aesim_metrics:new(),
    sim_dir => undefined,
    report_file => undefined,
    real_start_time => undefined,
    time => 0,
    max_real_time => infinity,
    max_sim_time => infinity,
    progress_sim_time => 0,
    progress_sim_interval => 0,
    progress_real_time => undefined,
    progress_real_interval => 0
  },
  Sim2 = setup_simulation(Opts, Sim),
  {Nodes, Sim3} = nodes_new(Sim2),
  {Scenario, Sim4} = scenario_new(Sim3),
  State = #{nodes => Nodes, scenario => Scenario},
  {State2, Sim5} = setup_metrics(State, Sim4),
  {State3, Sim6} = scenario_start(State2, Sim5),
  {State4, Sim7} = setup_progress(State3, Sim6),
  case loop(State4, Sim7) of
    {Reason, Sim8} ->
      cleanup_simulation(Sim8),
      Reason
  end.

-spec print(string(), [term()], sim()) -> ok.
print(Format, Params, #{report_file := undefined}) ->
  io:format(Format, Params);
print(Format, Params, #{report_file := ReportFile}) ->
  file:write(ReportFile, io_lib:format(Format, Params)),
  io:format(Format, Params).

-spec print_separator(sim()) -> ok.
print_separator(Sim) ->
  print("~s~n", [lists:duplicate(?LINE_LENGTH, ?HEADER_CHAR)], Sim).

-spec print_title(string(), sim()) -> ok.
print_title(Title, Sim) ->
  Prefix = lists:duplicate(?PREFIX_SIZE, ?HEADER_CHAR),
  PostfixSize = ?LINE_LENGTH - (length(Title) + 2 + length(Prefix)),
  Postfix = lists:duplicate(PostfixSize, ?HEADER_CHAR),
  print("~s ~s ~s~n", [Prefix, Title, Postfix], Sim).

-spec print_header(print_specs(), sim()) -> ok.
print_header(Specs, Sim) ->
  {Format, Values} = header_print_params(Specs),
  print(Format, Values, Sim).

-spec print_fields(print_specs(), [term()], sim()) -> ok.
print_fields(Specs, Fields, Sim) ->
  {Format, Values} = fields_print_params(Specs, Fields),
  print(Format, Values, Sim).

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

setup_metrics(State, Sim) ->
  {UpdateInterval, Sim2} = aesim_metrics:setup(Sim),
  {State#{metrics_interval => UpdateInterval}, Sim2}.

setup_progress(State, Sim) ->
  StartTime = erlang:system_time(millisecond),
  {State, Sim#{real_start_time => StartTime, progress_real_time => StartTime}}.

cleanup_simulation(Sim) ->
  Sim2 = aesim_metrics:cleanup(Sim),
  #{report_file := ReportFile} = Sim2,
  case ReportFile of
    undefined -> ok;
    File -> file:close(File)
  end.

-spec loop(state(), sim()) -> {termination_reason(), sim()}.
loop(State, Sim) ->
  RealNow = erlang:system_time(millisecond),
  case has_terminated(State, RealNow, Sim) of
    true ->
      scenario_report(State, timeout, Sim),
      {normal, Sim};
    false ->
      {State2, Sim2} = progress(State, RealNow, Sim),
      case aesim_events:next(Sim2) of
        {empty, Sim3} ->
          scenario_report(State2, frozen, Sim3),
          {frozen, Sim3};
        {NextTime, EAddr, EName, Params, Sim3} ->
          #{metrics_interval := Interval} = State2,
          Sim4 = update_time(Interval, NextTime, Sim3),
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

update_time(infinity, NextTime, Sim) ->
  #{time := Time} = Sim,
  Sim#{time := max(Time, NextTime)};
update_time(MetricsIterval, NextTime, Sim) ->
  #{time := Time} = Sim,
  Sim2 = case datapoints(MetricsIterval, Time, NextTime) of
    [] -> Sim;
    DataPoints ->
      aesim_metrics:update(DataPoints, Sim)
  end,
  Sim2#{time := max(Time, NextTime)}.

datapoints(Interval, Time1, Time2) ->
  Last = Time1 - (Time1 rem Interval),
  datapoints(Interval, Last, Time2, []).

datapoints(Interval, Time1, Time2, Acc) ->
  Next = Time1 + Interval,
  case Next =< Time2 of
    true -> datapoints(Interval, Next, Time2, [Next | Acc]);
    false -> lists:reverse(Acc)
  end.

route_event(State, [scenario], Name, Params, Sim) ->
  scenario_handle_event(State, Name, Params, Sim);
route_event(State, [nodes | Rest], Name, Params, Sim) ->
  nodes_route_event(State, Rest, Name, Params, Sim);
route_event(State, Addr, Name, Params, Sim) ->
  lager:warning("Unexpected simulator event ~p for ~p: ~p", [Name, Addr, Params]),
  {State, Sim}.

simulation_dir(_Sim) ->
  T = erlang:system_time(millisecond),
  Now = {T div 1000000000, (T div 1000) rem 1000000  , (T rem 1000) * 1000},
  {{Y, Mo, D}, {H, Mn, S}} = calendar:now_to_local_time(Now),
  Milli = T rem 1000,
  SubDir = aesim_utils:format("~4.10.0b~2.10.0b~2.10.0b~2.10.0b~2.10.0b~2.10.0b~3.10.0b",
                              [Y, Mo, D, H, Mn, S, Milli]),
  filename:join(?SIMULATIONS_DIR, SubDir).

%--- PRINT FUNCTIONS -----------------------------------------------------------

header_print_params(Specs) ->
  header_print_params(Specs, [], []).

header_print_params([], FmtAcc, ValAcc) ->
  Format = lists:flatten(lists:join(" ", lists:reverse(FmtAcc))),
  {Format ++ "~n", lists:reverse(ValAcc)};
header_print_params([Spec | Rest], FmtAcc, ValAcc) ->
  {_Type, Name, Just, _Unit, Size} = Spec,
  {Fmt, Val} = make_format(string, Just, truncate(Name, Size), undefined, Size),
  header_print_params(Rest, [Fmt | FmtAcc], [Val | ValAcc]).

fields_print_params(Specs, Values) ->
  fields_print_params(Specs, Values, [], []).

fields_print_params([], [], FmtAcc, ValAcc) ->
  Format = lists:flatten(lists:join(" ", lists:reverse(FmtAcc))),
  {Format ++ "~n", lists:reverse(ValAcc)};
fields_print_params([Spec | Specs], [Value | Values], FmtAcc, ValAcc) ->
  {Type, _Name, Just, Unit, Size} = Spec,
  {Fmt, Val} = make_format(Type, Just, Value, Unit, Size),
  fields_print_params(Specs, Values, [Fmt | FmtAcc], [Val | ValAcc]).

truncate(Str, Size) when is_list(Str) ->
  string:sub_string(Str, 1, Size).

resize(Str, Size) when is_list(Str), length(Str) =< Size -> Str;
resize(_Str, Size) -> lists:duplicate(Size, ?NO_SPACE_CHAR).

make_format(Type, left, Field, Unit, Size) ->
  Value = resize(convert(Type, Field, Unit), Size),
  {aesim_utils:format("~~~ws", [-Size]), Value};
make_format(Type, right, Field, Unit, Size) ->
  Value = resize(convert(Type, Field, Unit), Size),
  {aesim_utils:format("~~~ws", [Size]), Value}.

convert(string, Value, undefined) when is_list(Value) ->
  Value;
convert(string, Value, Unit) when is_list(Value) ->
  aesim_utils:format("~s~s", [Value, Unit]);
convert(integer, Value, undefined) when is_integer(Value) ->
  aesim_utils:format("~w", [Value]);
convert(integer, Value, Unit) when is_integer(Value) ->
  aesim_utils:format("~w~s", [Value, Unit]);
convert(time, Value, undefined) when is_integer(Value) ->
  aesim_utils:format_time(Value);
convert(speed, Value, _) when Value == 0 -> "N/A";
convert(speed, Value, undefined) when is_float(Value), Value >= 1 ->
  aesim_utils:format("~b", [round(Value)]);
convert(speed, Value, Unit) when is_float(Value), Value >= 1 ->
  aesim_utils:format("~b~s", [round(Value), Unit]);
convert(speed, Value, undefined) when is_float(Value) ->
  aesim_utils:format("1/~b", [round(1 / Value)]);
convert(speed, Value, Unit) when is_float(Value) ->
  aesim_utils:format("1/~b~s", [round(1 / Value), Unit]).

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
    fun aesim_metrics:parse_options/2,
    {scenario_mod, parse_options},
    fun aesim_nodes:parse_options/2
  ]).

cfg_max_real_time(Sim) -> aesim_config:get(Sim, max_real_time).

cfg_max_sim_time(Sim) -> aesim_config:get(Sim, max_sim_time).

cfg_scenario_mod(Sim) -> aesim_config:get(Sim, scenario_mod).

cfg_progress_interval(Sim) -> aesim_config:get(Sim, progress_interval).

