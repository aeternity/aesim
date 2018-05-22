-module(aesim_scenario).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== BEHAVIOUR DEFINITION ======================================================

-callback parse_options(Config, Opts)
  -> Config
  when Config :: map(),
       Opts :: map().

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
       Reason :: timeout | frozen,
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
-export([print_separator/0]).
-export([print_title/1]).
-export([print_header/1]).
-export([print_fields/2]).
-export([calculate_progress/1]).
-export([node_metrics/2]).
-export([reduce_metric/1]).

%=== MACROS ====================================================================

-define(LINE_LENGTH, 80).
-define(PREFIX_SIZE, 3).
-define(HEADER_CHAR, $#).
-define(NO_SPACE_CHAR, $*).

%=== TYPES =====================================================================

-type print_type() :: string | integer | time | speed.
-type print_just() :: left | right.
-type print_spec() :: {print_type(), string(), print_just(), string() | undefined, pos_integer()}.
-type print_specs() :: [print_spec()].

%=== API FUNCTIONS =============================================================

-spec post(delay(), event_name(), term(), sim()) -> {event_ref(), sim()}.
post(Delay, Name, Params, Sim) ->
  aesim_events:post(Delay, [scenario], Name, Params, Sim).

-spec print_separator() -> ok.
print_separator() ->
  aesim_utils:print("~s~n", [lists:duplicate(?LINE_LENGTH, ?HEADER_CHAR)]).

-spec print_title(string()) -> ok.
print_title(Title) ->
  Prefix = lists:duplicate(?PREFIX_SIZE, ?HEADER_CHAR),
  PostfixSize = ?LINE_LENGTH - (length(Title) + 2 + length(Prefix)),
  Postfix = lists:duplicate(PostfixSize, ?HEADER_CHAR),
  aesim_utils:print("~s ~s ~s~n", [Prefix, Title, Postfix]).

-spec print_header(print_specs()) -> ok.
print_header(Specs) ->
  {Format, Values} = header_print_params(Specs),
  aesim_utils:print(Format, Values).

-spec print_fields(print_specs(), [term()]) -> ok.
print_fields(Specs, Fields) ->
  {Format, Values} = fields_print_params(Specs, Fields),
  aesim_utils:print(Format, Values).

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

node_metrics(Nodes, Sim) ->
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
    {"Inbound connections", reduce_metric(IcValues)},
    {"Outbound connections", reduce_metric(OcValues)},
    {"Known peers", reduce_metric(KcValues)},
    {"Known peers (%)", reduce_metric(KpValues)},
    {"Pooled verified peers", reduce_metric(VcValues)},
    {"Pooled verified peers (%)", reduce_metric(VpValues)}
  ].

reduce_metric([_|_] = Values) ->
  {Total, Min, Max, Count} = lists:foldl(fun(V, {T, Mn, Mx, C}) ->
    {T + V, safe_min(Mn, V), safe_max(Mx, V), C + 1}
  end, {0, undefined, undefined, 0}, Values),
  Avg = round(Total / Count),
  Median = lists:nth(max(Count div 2, 1), lists:sort(Values)),
  {Min, Avg, Median, Max}.

%=== INTERNAL FUNCTIONS ========================================================

safe_min(undefined, V) -> V;
safe_min(V1, V2) -> min(V1, V2).

safe_max(undefined, V) -> V;
safe_max(V1, V2) -> max(V1, V2).

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
