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
-export([calculate_progress/1]).
-export([nodes_status/2]).
-export([default_start/2]).
-export([default_progress/2]).
-export([default_report/3]).

%=== MACROS ====================================================================

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
-define(STATUS_SPECS, [
  {string, "DESCRIPTION", left, undefined, 48},
  {integer, "MINIMUM", right, undefined, 7},
  {integer, "AVERAGE", right, undefined, 7},
  {integer, "MEDIAN", right, undefined, 7},
  {integer, "MAXIMUM", right, undefined, 7}
]).

%=== API FUNCTIONS =============================================================

-spec post(delay(), event_name(), term(), sim()) -> {event_ref(), sim()}.
post(Delay, Name, Params, Sim) ->
  aesim_events:post(Delay, [scenario], Name, Params, Sim).

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


% -dialyzer({nowarn_function, nodes_status/2}).
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
  aesim_simulator:print_title("CONFIGURATION", Sim2),
  aesim_config:print_config(Sim2),
  aesim_simulator:print_title("SIMULATION", Sim2),
  aesim_simulator:print_header(?PROGRESS_SPECS, Sim2),
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
  aesim_simulator:print_fields(?PROGRESS_SPECS, Fields, Sim).

-spec default_report(termination_reason(), aesim_nodes:state(), sim()) -> ok.
default_report(_Reason, Nodes, Sim) ->
  aesim_simulator:print_title("EVENTS STATUS", Sim),
  aesim_events:print_summary(Sim),

  aesim_simulator:print_title("NODES STATUS", Sim),
  aesim_simulator:print_header(?STATUS_SPECS, Sim),
  lists:foreach(fun({Desc, {Min, Avg, Med, Max}}) ->
    Fields = [Desc, Min, Avg, Med, Max],
    aesim_simulator:print_fields(?STATUS_SPECS, Fields, Sim)
  end, nodes_status(Nodes, Sim)),

  aesim_simulator:print_title("DEBUG", Sim),
  TrustedIds = [I || {I, _} <- aesim_nodes:trusted(Nodes)],
  Desc = fun(Id) ->
    case lists:member(Id, TrustedIds) of
      true -> " (trusted)";
      false -> ""
    end
  end,
  Data = aesim_nodes:reduce(Nodes, fun(I, N, Acc) ->
    C = aesim_node:connections(N),
    [{-aesim_connections:count(C, outbound),
      -aesim_connections:count(C, inbound), I}
    | Acc]
  end, []),
  {MaxOuts, _} = lists:split(4, lists:keysort(1, Data)),
  {MaxIns, _} = lists:split(4, lists:keysort(2, Data)),
  aesim_simulator:print("Nodes with the most outbound connections:~n", [], Sim),
  lists:foreach(fun({Max, _, Id}) ->
    aesim_simulator:print("  Node ~4b: ~5b connection(s)~s~n",
                          [Id, -Max, Desc(Id)], Sim)
  end, MaxOuts),
  aesim_simulator:print("Nodes with the most inbound connections:~n", [], Sim),
  lists:foreach(fun({_, Max, Id}) ->
    aesim_simulator:print("  Node ~4b: ~5b connection(s)~s~n",
                          [Id, -Max, Desc(Id)], Sim)
  end, MaxIns),

  aesim_metrics:print_report(Sim),
  ok.
