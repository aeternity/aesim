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
  -> {State, Sim} | {State, PhaseSpecs, Sim}
  when State :: term(),
       PhaseSpecs :: phase_specs(),
       Sim :: sim().

-callback scenario_start(State, Nodes, Sim)
  -> {State, Nodes, Sim} | {State, StartPhaseTag, Nodes, Sim}
  when State :: term(),
       StartPhaseTag :: phase_tag(),
       Nodes :: aesim_nodes:state(),
       Sim :: sim().

-callback scenario_phase_start(State, Phase, Nodes, Sim)
  -> {State, Nodes, Sim}
  when State :: term(),
       Phase :: phase(),
       Nodes :: aesim_nodes:state(),
       Sim :: sim().

-callback scenario_phase_stop(State, Phase, Nodes, Sim)
  -> {State, Nodes, Sim}
  when State :: term(),
       Phase :: phase(),
       Nodes :: aesim_nodes:state(),
       Sim :: sim().

-callback scenario_phase_check(State, Phase, Nodes, Sim)
  -> continue | {next, PhaseTag} | {stop, Reason}
  when State :: term(),
       Phase :: phase(),
       PhaseTag :: phase_tag(),
       Nodes :: aesim_nodes:state(),
       Reason :: termination_reason(),
       Sim :: sim().

%% This is called for every iteration loop of the simulation;
%% it shouldn't do any heavy calculation or simulation will get slow.
-callback scenario_has_terminated(State, Nodes, Sim)
  -> continue | {stop, Reason}
  when State :: term(),
       Nodes :: aesim_nodes:state(),
       Reason :: termination_reason(),
       Sim :: sim().

-callback scenario_progress(State, Phase, Nodes, Sim)
  -> {State, Sim}
  when State :: term(),
       Phase :: undefined | phase(),
       Nodes :: aesim_nodes:state(),
       Sim :: sim().

-callback scenario_report(State, Reason, Nodes, Sim)
  -> Reason
  when State :: term(),
       Reason :: termination_reason(),
       Nodes :: aesim_nodes:state(),
       Sim :: sim().

-callback scenario_handle_event(State, Phase, EventName, Params, Nodes, Sim)
  -> ignore | {State, Sim}
  when State :: term(),
       Phase :: undefined | phase(),
       EventName :: event_name(),
       Params :: term(),
       Nodes :: aesim_nodes:state(),
       Sim :: sim().

-optional_callbacks([
  scenario_phase_start/4,
  scenario_phase_stop/4,
  scenario_phase_check/4,
  scenario_has_terminated/3,
  scenario_progress/4,
  scenario_report/4
]).

%=== EXPORTS ===================================================================

-export([post/4]).
-export([calculate_progress/1]).
-export([nodes_status/2]).
-export([default_start/2]).
-export([default_progress_header/1]).
-export([default_progress/3]).
-export([default_report/3]).
-export([print_event_status/1]).
-export([print_node_status/2]).
-export([print_oulier_info/2]).
-export([print_phase_start/2]).
-export([print_phase_stop/2]).

%=== TYPES =====================================================================

-type phase_tag() :: atom().
-type phase_spec() :: {
  Description :: string(),
  Tag :: phase_tag(),
  CheckInterval :: sim_time()
}.
-type phase_specs() :: [phase_spec()].

-type phase() :: #{
  tag := phase_tag(),
  index := pos_integer(),
  desc := string(),
  check_interval := infinity | delay(),
  sim_start_time := sim_time(),
  sim_stop_time := undefined | sim_time()
}.

-export_type([
  phase_tag/0,
  phase_spec/0,
  phase_specs/0,
  phase/0
]).

%=== MACROS ====================================================================

-define(OUTLIER_COUNT, 4).

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
  {Nodes2, Sim2}.

-spec default_progress_header(sim()) -> ok.
default_progress_header(Sim) ->
  aesim_simulator:print_header(?PROGRESS_SPECS, Sim).

-spec default_progress(phase() | undefined, aesim_nodes:state(), sim()) -> ok.
default_progress(_Phase, Nodes, Sim) ->
  #{progress_counter := ProgressCounter} = Sim,
  if ProgressCounter =:= 1 -> default_progress_header(Sim); true -> ok end,
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
  print_event_status(Sim),
  print_node_status(Nodes, Sim),
  print_oulier_info(Nodes, Sim),
  aesim_metrics:print_report(Sim).

-spec print_event_status(sim()) -> ok.
print_event_status(Sim) ->
  aesim_simulator:print_title("EVENTS STATUS", Sim),
  aesim_events:print_summary(Sim).

-spec print_node_status(aesim_nodes:state(), sim()) -> ok.
print_node_status(Nodes, Sim) ->
  aesim_simulator:print_title("NODES STATUS", Sim),
  aesim_simulator:print_header(?STATUS_SPECS, Sim),
  lists:foreach(fun({Desc, {Min, Avg, Med, Max}}) ->
    Fields = [Desc, Min, Avg, Med, Max],
    aesim_simulator:print_fields(?STATUS_SPECS, Fields, Sim)
  end, nodes_status(Nodes, Sim)).

-spec print_oulier_info(aesim_nodes:state(), sim()) -> ok.
print_oulier_info(Nodes, Sim) ->
  aesim_simulator:print_title("OUTLIER INFORMATION", Sim),
  TrustedIds = [I || {I, _} <- aesim_nodes:trusted(Nodes)],

  NodeInfoFun = fun(Id) ->
    case lists:member(Id, TrustedIds) of
      true -> " (trusted)";
      false -> ""
    end
  end,

  PrintNodesFun = fun(Selection, Idx, Factor, Unit) ->
    lists:foreach(fun({NodeId, _, _, _} = Record) ->
    Value = element(Idx, Record),
    Info = NodeInfoFun(NodeId),
    aesim_simulator:print("  Node ~4b: ~5b ~s~s~n",
                          [NodeId, Factor * Value, Unit, Info], Sim)
    end, Selection)
  end,

  {MinData, MaxData} = aesim_nodes:reduce(Nodes,fun(I, N, {MinAcc, MaxAcc}) ->
    Conns = aesim_node:connections(N),
    Pool = aesim_node:pool(N),
    CO = aesim_connections:count(Conns, outbound),
    CI = aesim_connections:count(Conns, inbound),
    PV = aesim_pool:count(Pool, verified),
    {[{I, CO, CI, PV} | MinAcc], [{I, -CO, -CI, -PV} | MaxAcc]}
  end, {[], []}),
  {MaxCOs, _} = lists:split(?OUTLIER_COUNT, lists:keysort(2, MaxData)),
  {MinCOs, _} = lists:split(?OUTLIER_COUNT, lists:keysort(2, MinData)),
  {MaxCIs, _} = lists:split(?OUTLIER_COUNT, lists:keysort(3, MaxData)),
  {MinCIs, _} = lists:split(?OUTLIER_COUNT, lists:keysort(3, MinData)),
  {MaxPVs, _} = lists:split(?OUTLIER_COUNT, lists:keysort(4, MaxData)),
  {MinPVs, _} = lists:split(?OUTLIER_COUNT, lists:keysort(4, MinData)),
  aesim_simulator:print("Nodes with the MOST outbound connections:~n", [], Sim),
  PrintNodesFun(MaxCOs, 2, -1, "connection(s)"),
  aesim_simulator:print("Nodes with the LESS outbound connections:~n", [], Sim),
  PrintNodesFun(MinCOs, 2, 1, "connection(s)"),
  aesim_simulator:print("Nodes with the MOST inbound connections:~n", [], Sim),
  PrintNodesFun(MaxCIs, 3, -1, "connection(s)"),
  aesim_simulator:print("Nodes with the LESS inbound connections:~n", [], Sim),
  PrintNodesFun(MinCIs, 3, 1, "connection(s)"),
  aesim_simulator:print("Nodes with the MOST pooled verified peers:~n", [], Sim),
  PrintNodesFun(MaxPVs, 4, -1, "peer(s)"),
  aesim_simulator:print("Nodes with the LESS pooled verified peers:~n", [], Sim),
  PrintNodesFun(MinPVs, 4, 1, "peer(s)"),
  ok.

-spec print_phase_start(phase(), sim()) -> ok.
print_phase_start(Phase, Sim) ->
  #{tag := Tag, index := Idx, desc := Desc} = Phase,
  Title = aesim_utils:format("PHASE ~2b START : ~w", [Idx, Tag]),
  aesim_simulator:print_comment(Title, Sim),
  aesim_simulator:print_comment(Desc, Sim).

-spec print_phase_stop(phase(), sim()) -> ok.
print_phase_stop(Phase, Sim) ->
  #{index := Idx, sim_start_time := StartTime, sim_stop_time := StopTime} = Phase,
  Duration = aesim_utils:format_time(StopTime - StartTime),
  Title = aesim_utils:format("PHASE ~2b DONE  : ~s", [Idx, Duration]),
  aesim_simulator:print_comment(Title, Sim),
  aesim_simulator:print_separator(Sim).
  
