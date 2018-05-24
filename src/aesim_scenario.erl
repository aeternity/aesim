-module(aesim_scenario).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== BEHAVIOUR DEFINITION ======================================================

-callback parse_options(Opts, Sim)
  -> Sim
  when Opts :: map(),
       Sim :: sim().

-callback scenario_new(Sim)
  -> {State, Sim}
  when State :: term(),
       Sim :: sim().

-callback scenario_start(State, Nodes, Sim)
  -> {State, Nodes, Sim}
  when State :: term(),
       Nodes :: aesim_nodes:state(),
       Sim :: sim().

-callback scenario_has_terminated(State, Nodes, Sim)
  -> boolean()
  when State :: term(),
       Nodes :: aesim_nodes:state(),
       Sim :: sim().

-callback scenario_progress(State, Nodes, Sim)
  -> {State, Sim}
  when State :: term(),
       Nodes :: aesim_nodes:state(),
       Sim :: sim().

-callback scenario_report(State, Reason, Nodes, Sim)
  -> ok
  when State :: term(),
       Reason :: termination_reason(),
       Nodes :: aesim_nodes:state(),
       Sim :: sim().

-callback scenario_handle_event(State, EventName, Params, Nodes, Sim)
  -> ignore | {State, Sim}
  when State :: term(),
       EventName :: event_name(),
       Params :: term(),
       Nodes :: aesim_nodes:state(),
       Sim :: sim().

%=== EXPORTS ===================================================================

-export([post/4]).
-export([print_separator/1]).
-export([print_title/2]).
-export([print_header/2]).
-export([print_fields/3]).
-export([calculate_progress/1]).
-export([nodes_status/2]).
-export([default_start/2]).
-export([default_progress/2]).
-export([default_report/3]).

%=== MACROS ====================================================================

-define(LINE_LENGTH, 80).
-define(PREFIX_SIZE, 3).
-define(HEADER_CHAR, $#).
-define(NO_SPACE_CHAR, $*).
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
-define(METRIC_SPECS, [
  {string, "DESCRIPTION", left, undefined, 48},
  {integer, "MINIMUM", right, undefined, 7},
  {integer, "AVERAGE", right, undefined, 7},
  {integer, "MEDIAN", right, undefined, 7},
  {integer, "MAXIMUM", right, undefined, 7}
]).

%=== TYPES =====================================================================

-type termination_reason() :: timeout | frozen.
-type print_type() :: string | integer | time | speed.
-type print_just() :: left | right.
-type print_spec() :: {print_type(), string(), print_just(), string() | undefined, pos_integer()}.
-type print_specs() :: [print_spec()].

%=== API FUNCTIONS =============================================================

-spec post(delay(), event_name(), term(), sim()) -> {event_ref(), sim()}.
post(Delay, Name, Params, Sim) ->
  aesim_events:post(Delay, [scenario], Name, Params, Sim).

-spec print_separator(sim()) -> ok.
print_separator(Sim) ->
  aesim_simulator:print("~s~n", [lists:duplicate(?LINE_LENGTH, ?HEADER_CHAR)], Sim).

-spec print_title(string(), sim()) -> ok.
print_title(Title, Sim) ->
  Prefix = lists:duplicate(?PREFIX_SIZE, ?HEADER_CHAR),
  PostfixSize = ?LINE_LENGTH - (length(Title) + 2 + length(Prefix)),
  Postfix = lists:duplicate(PostfixSize, ?HEADER_CHAR),
  aesim_simulator:print("~s ~s ~s~n", [Prefix, Title, Postfix], Sim).

-spec print_header(print_specs(), sim()) -> ok.
print_header(Specs, Sim) ->
  {Format, Values} = header_print_params(Specs),
  aesim_simulator:print(Format, Values, Sim).

-spec print_fields(print_specs(), [term()], sim()) -> ok.
print_fields(Specs, Fields, Sim) ->
  {Format, Values} = fields_print_params(Specs, Fields),
  aesim_simulator:print(Format, Values, Sim).

-spec calculate_progress(sim()) -> map().
calculate_progress(Sim) ->
  #{real_start_time := RealStartTime,
    max_sim_time := SimMaxTime,
    progress_sim_time := SimProgress,
    progress_sim_interval := SimInterval,
    progress_real_time := RealProgress,
    progress_real_interval := RealInterval
  } = Sim,
  Progress = case SimMaxTime =:= infinity of
    false -> (SimProgress * 100) div SimMaxTime;
    true -> 0
  end,
  #{
    progress => Progress,
    real_time => RealProgress - RealStartTime,
    sim_time => SimProgress,
    current_speed => SimInterval / RealInterval,
    global_speed => SimProgress / (RealProgress - RealStartTime)
  }.

nodes_status(Nodes, Sim) ->
  #{nodes := NodeReports} = aesim_nodes:report(Nodes, complete, Sim),
  NodeCount = aesim_nodes:count(Nodes),
  {IcValues, OcValues, KcValues, KpValues, VcValues, VpValues}
    = lists:foldl(fun(R, {IcAcc, OcAcc, KcAcc, KpAcc, VcAcc, VpAcc}) ->
      #{known_peers_count := Kc,
        pool := PoolReport,
        connections := ConnReports
      } = R,
      #{verified_count := Vc} = PoolReport,
      #{outbound_count := Oc,
        inbound_count := Ic
      } = ConnReports,
      Kp = round(Kc * 100 / (NodeCount - 1)),
      Vp = round(Vc * 100 / (NodeCount - 1)),
      {[Ic | IcAcc], [Oc | OcAcc], [Kc | KcAcc],
       [Kp | KpAcc], [Vc | VcAcc], [Vp | VpAcc]}
    end, {[], [], [], [], [], []}, NodeReports),
  [
    {"Inbound connections", aesim_utils:reduce_metric(IcValues)},
    {"Outbound connections", aesim_utils:reduce_metric(OcValues)},
    {"Known peers", aesim_utils:reduce_metric(KcValues)},
    {"Known peers (%)", aesim_utils:reduce_metric(KpValues)},
    {"Pooled verified peers", aesim_utils:reduce_metric(VcValues)},
    {"Pooled verified peers (%)", aesim_utils:reduce_metric(VpValues)}
  ].

-spec default_start(aesim_nodes:state(), sim()) -> {aesim_nodes:state(), sim()}.
default_start(Nodes, Sim) ->
  {Nodes2, Sim2} = aesim_nodes:bootstrap(Nodes, Sim),
  print_title("CONFIGURATION", Sim2),
  aesim_config:print_config(Sim2),
  print_title("SIMULATION", Sim2),
  print_header(?PROGRESS_SPECS, Sim2),
  {Nodes2, Sim2}.

-spec default_progress(aesim_nodes:state(), sim()) -> ok.
default_progress(Nodes, Sim) ->
  EventCount = aesim_events:size(Sim),
  #{progress := Progress,
    real_time := RealTime,
    sim_time := SimTime,
    current_speed := CurrSpeed,
    global_speed := GlobSpeed
  } = calculate_progress(Sim),
  #{node_count := NodeCount,
    connection_count := ConnCount
  } = aesim_nodes:report(Nodes, simple, Sim),
  Fields = [Progress, RealTime, SimTime, CurrSpeed, GlobSpeed,
            NodeCount, ConnCount, EventCount],
  print_fields(?PROGRESS_SPECS, Fields, Sim).

-spec default_report(termination_reason(), aesim_nodes:state(), sim()) -> ok.
default_report(_Reason, Nodes, Sim) ->
  print_title("EVENTS STATUS", Sim),
  aesim_events:print_summary(Sim),
  print_title("NODES STATUS", Sim),
  print_header(?METRIC_SPECS, Sim),
  lists:foreach(fun({Desc, {Min, Avg, Med, Max}}) ->
    Fields = [Desc, Min, Avg, Med, Max],
    print_fields(?METRIC_SPECS, Fields, Sim)
  end, nodes_status(Nodes, Sim)),
  print_title("NODES METRICS", Sim),
  print_header(?METRIC_SPECS, Sim),
  SortedMetrics = lists:keysort(1, aesim_metrics:collect_nodes_metrics(Sim)),
  lists:foreach(fun({Name, {Min, Avg, Med, Max}}) ->
    Desc = aesim_metrics:name_to_list(Name),
    Fields = [Desc, Min, Avg, Med, Max],
    print_fields(?METRIC_SPECS, Fields, Sim)
  end, SortedMetrics),
  ok.

%=== INTERNAL FUNCTIONS ========================================================

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
convert(speed, Value, undefined) when is_float(Value), Value >= 1 ->
  aesim_utils:format("~b", [round(Value)]);
convert(speed, Value, Unit) when is_float(Value), Value >= 1 ->
  aesim_utils:format("~b~s", [round(Value), Unit]);
convert(speed, Value, undefined) when is_float(Value) ->
  aesim_utils:format("1/~b", [round(1 / Value)]);
convert(speed, Value, Unit) when is_float(Value) ->
  aesim_utils:format("1/~b~s", [round(1 / Value), Unit]).
