-module(aesim_metrics).

%% @doc Simulation metrics managment
%%
%% To add a new metrics it needs to be added to `RRD_SOURCES` macro **AND**
%% `k2i` lookup function.
%% To add a graph for it, add an entry to `RRD_GRAPHS` macro.

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include_lib("errd/include/errd.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

-export([parse_options/2]).
-export([new/0]).
-export([setup/1]).
-export([cleanup/1]).
-export([update/2]).
-export([inc/3, inc/4]).
-export([get/2, get/3]).

-export([name_to_list/1]).
-export([collect_nodes_metrics/1]).
-export([print_report/1]).

%=== MACROS ====================================================================

-define(DEFAULT_RRD_ENABLED, false).
-define(UPDATE_INTERVAL, (60 * 1000)). % 1 minute
-define(METRICS_DIR, "metrics").
-define(RRD_FILE, "metrics.rrd").
-define(RRD_INDEX_FILE, "metrics.html").
-define(RRD_IMAGE_DIR, "images").

-define(RRD_GRAPH_WIDTH, 1000).
-define(RRD_GRAPH_HEIGHT, 300).
-define(RRD_COLOR_SIMPLE, "#000099").
-define(RRD_COLOR_MIN,    "#009900").
-define(RRD_COLOR_AVG,    "#009999").
-define(RRD_COLOR_MED,    "#000099").
-define(RRD_COLOR_MAX,    "#990000").

-define(METRIC_SPECS, [
  {string, "DESCRIPTION", left, undefined, 48},
  {integer, "MINIMUM", right, undefined, 7},
  {integer, "AVERAGE", right, undefined, 7},
  {integer, "MEDIAN", right, undefined, 7},
  {integer, "MAXIMUM", right, undefined, 7}
]).

-define(RRD_SOURCES, [
  [nodes, count],
  [connections, count, inbound],
  [connections, count, outbound],
  [connections, connect],
  [connections, rejected],
  [connections, accepted],
  [connections, failed],
  [connections, retry],
  [connections, established],
  [connections, disconnect],
  [connections, terminated, inbound],
  [connections, terminated, outbound],
  [connections, pruned],
  [peers, expired],
  [gossip, received],
  [pool, known],
  [pool, verified]
]).

-define(RRD_GRAPHS, [
  #{title => "Running Nodes",
    defs => {simple, "nodes", #{}}},
  #{title => "Inbound Connections per Node",
    defs => {collection, "conns_in", #{}}},
  #{title => "Outbound Connections per Node",
    defs => {collection, "conns_out", #{}}},
  #{title => "Pruned Connections per Node",
    defs => {collection, "pruned", #{}}},
  #{title => "Gossip Updates Received per Node",
    defs => {collection, "gossiped", #{}}},
  #{title => "Pooled Peers per Node",
    defs => {collection, "known", #{}}},
  #{title => "Failed Connections per Node",
    defs => {collection, "failed", #{}}},
  #{title => "Retried Connections per Node",
    defs => {collection, "retry", #{}}},
  #{title => "Expired Peers per Node",
    defs => {collection, "expired", #{}}}
]).

%=== TYPES =====================================================================

-type metric_name() :: [atom()].

-type metrics() :: #{metric_name() => integer()}.

-type state() :: #{
  rrd_enabled := boolean(),
  rrd_server := pid() | undefined,
  rrd_dir := string() | undefined,
  rrd_start_time := pos_integer() | undefined,
  global := metrics(),
  nodes := #{id() => metrics()}
}.

-export_type([state/0]).

%=== API FUNCTIONS =============================================================

-spec parse_options(map(), sim()) -> sim().
parse_options(Opts, Sim) ->
  aesim_config:parse(Sim, Opts, [
    {rrd_enabled, boolean, ?DEFAULT_RRD_ENABLED}
  ]).

-spec new() -> state().
new() ->
  #{rrd_enabled => false,
    rrd_server => undefined,
    rrd_dir => undefined,
    rrd_start_time => undefined,
    global => new_metrics(),
    nodes => #{}
  }.

-spec setup(sim()) -> {pos_integer() | infinity, sim()}.
setup(Sim) ->
  case cfg_rrd_enabled(Sim) of
    false -> {infinity, Sim};
    true -> rrd_setup(Sim)
  end.

-spec cleanup(sim()) -> sim().
cleanup(Sim) ->
  case cfg_rrd_enabled(Sim) of
    false -> Sim;
    true -> rrd_cleanup(Sim)
  end.

-spec update([sim_time()], sim()) -> sim().
update([], Sim) -> Sim;
update(DataPoints, Sim) ->
  #{metrics := State} = Sim,
  State2 = rrd_update(State, DataPoints),
  Sim#{metrics := State2}.

-spec inc(metric_name(), integer(), sim()) -> sim().
inc(_Name, 0, Sim) -> Sim;
inc(Name, Inc, Sim) ->
  #{metrics := State} = Sim,
  #{global := GlobalMetrics} = State,
  GlobalMetrics2 = metrics_inc(GlobalMetrics, Name, Inc),
  Sim#{metrics := State#{global := GlobalMetrics2}}.

-spec inc(id(), metric_name(), integer(), sim()) -> sim().
inc(_NodeId, _Name, 0, Sim) -> Sim;
inc(NodeId, Name, Inc, Sim) ->
  #{metrics := State} = Sim,
  #{nodes := NodesMetrics} = State,
  NodeMetrics = case maps:find(NodeId, NodesMetrics) of
    error -> new_metrics();
    {ok, Value} -> Value
  end,
  NodeMetrics2 = metrics_inc(NodeMetrics, Name, Inc),
  Sim#{metrics := State#{nodes := NodesMetrics#{NodeId => NodeMetrics2}}}.

-spec get(metric_name(), sim()) -> integer().
get(Name, Sim) ->
  #{metrics := State} = Sim,
  #{global := GlobalMetrics} = State,
  metrics_get(GlobalMetrics, Name).

-spec get(id(), metric_name(), sim()) -> integer().
get(NodeId, Name, Sim) ->
  #{metrics := State} = Sim,
  #{nodes := NodesMetrics} = State,
  case maps:find(NodeId, NodesMetrics) of
    {ok, NodeMetrics} -> metrics_get(NodeMetrics, Name);
    error -> 0
  end.

-spec name_to_list(metric_name()) -> string().
name_to_list(Name) ->
  lists:flatten(lists:join($., [atom_to_list(A) || A <- Name])).

-spec collect_nodes_metrics(sim()) -> [{metric_name(), {integer(), integer(), integer(), integer()}}].
collect_nodes_metrics(Sim) ->
  #{metrics := State} = Sim,
  reduce_node_metrics(State, []).

-spec print_report(sim()) -> ok.
print_report(Sim) ->
  #{metrics := State} = Sim,
  #{rrd_server := RRDServer} = State,
  aesim_simulator:print_title("NODES METRICS", Sim),
  aesim_simulator:print_header(?METRIC_SPECS, Sim),
  SortedMetrics = lists:keysort(1, collect_nodes_metrics(Sim)),
  lists:foreach(fun({Name, {Min, Avg, Med, Max}}) ->
    Desc = name_to_list(Name),
    Fields = [Desc, Min, Avg, Med, Max],
    aesim_simulator:print_fields(?METRIC_SPECS, Fields, Sim)
  end, SortedMetrics),
  case RRDServer of
    undefined -> ok;
    _ -> rrd_print_report(Sim)
  end.

%=== INTERNAL FUNCTIONS ========================================================

new_metrics() -> #{}.

metrics_inc(Metrics, Name, Inc) ->
  Current = maps:get(Name, Metrics, 0),
  New = Current + Inc,
  ?assert(New >= 0),
  Metrics#{Name => New}.

metrics_get(Metrics, Name) ->
  maps:get(Name, Metrics, 0).

reduce_node_metrics(State, Acc) ->
  #{nodes := NodesMetrics} = State,
  Metrics = lists:foldl(fun(Counters, Acc2) ->
    maps:fold(fun(N, V, Acc3) ->
      Acc3#{N => [V | maps:get(N, Acc3, [])]}
    end, Acc2, Counters)
  end, #{}, maps:values(NodesMetrics)),
  lists:foldl(fun({N, Values}, Acc2) ->
    [{N, aesim_utils:reduce_metric(Values)} | Acc2]
  end, Acc, maps:to_list(Metrics)).

%--- RRD FUNCTIONS -------------------------------------------------------------

k2i([nodes, count]) ->                      {simple,     gauge, "nodes"};
k2i([connections, count, outbound]) ->      {collection, gauge, "conns_out"};
k2i([connections, count, inbound]) ->       {collection, gauge, "conns_in"};
k2i([connections, connect]) ->              {collection, gauge, "connect"};
k2i([connections, rejected]) ->             {collection, gauge, "rejected"};
k2i([connections, accepted]) ->             {collection, gauge, "accepted"};
k2i([connections, failed]) ->               {collection, gauge, "failed"};
k2i([connections, retry]) ->                {collection, gauge, "retry"};
k2i([connections, established]) ->          {collection, gauge, "established"};
k2i([connections, disconnect]) ->           {collection, gauge, "disconnect"};
k2i([connections, terminated, inbound]) ->  {collection, gauge, "closed_in"};
k2i([connections, terminated, outbound]) -> {collection, gauge, "closed_out"};
k2i([connections, pruned]) ->               {collection, gauge, "pruned"};
k2i([gossip, received]) ->                  {collection, gauge, "gossiped"};
k2i([pool, known]) ->                       {collection, gauge, "known"};
k2i([pool, verified]) ->                    {collection, gauge, "verified"};
k2i([pool, unverified]) ->                  {collection, gauge, "unverified"};
k2i([peers, expired]) ->                    {collection, gauge, "expired"};
k2i(_) ->                                   undefined.

rrd_setup(Sim) ->
  #{metrics := State, max_sim_time := MaxTime, sim_dir := SimDir} = Sim,
  try
      {ok, Server} = errd_server:start_link(),
      RRDDir = filename:join(SimDir, ?METRICS_DIR),
      ok = filelib:ensure_dir(filename:join(RRDDir, "dummy")),
      State2 = State#{rrd_server := Server, rrd_dir := RRDDir},
      {ok, _} = errd_server:cd(Server, RRDDir),
      State3 = rrd_create(State2, MaxTime),
      {?UPDATE_INTERVAL, Sim#{metrics := State3}}
  catch
    _:_ ->
      aesim_simulator:print(
        "ERROR: Failed to start RRD server; RRD disabled~n", [], Sim),
      {infinity, Sim}
  end.

rrd_cleanup(Sim) ->
  #{metrics := State} = Sim,
  case State of
    #{rrd_server := undefined} -> Sim;
    #{rrd_server := Pid} ->
      ok = errd_server:stop(Pid),
      Sim#{metrics := State#{rrd_server := undefined}}
  end.

rrd_print_report(Sim) ->
  #{metrics := State, max_sim_time := MaxTime} = Sim,
  #{rrd_server := Server, rrd_start_time := Start, rrd_dir := RRDDir} = State,
  End = Start + MaxTime div 1000,
  ok = filelib:ensure_dir(filename:join([RRDDir, ?RRD_IMAGE_DIR, "dummy"])),
  RRDFilePath = filename:join(RRDDir, ?RRD_FILE),
  aesim_simulator:print_title("METRICS GRAPHS", Sim),
  aesim_simulator:print("DATABASE: ~s~n", [RRDFilePath], Sim),
  aesim_simulator:print("RRDTOOL PARAMETERS: --start ~b --end ~b~n",
                       [Start, End], Sim),
  Images = lists:map(fun(Spec) ->
    rrd_generate_graph(Server, Spec, Start, End)
  end, ?RRD_GRAPHS),
  IndexPath = rrd_generate_index(RRDDir, Images),
  aesim_simulator:print("INDEX: file://~s~n", [IndexPath], Sim),
  ok.

rrd_generate_graph(Server, Spec, Start, End) ->
  #{title := Title, defs := Defs} = Spec,
  case Defs of
    {simple, Name, _Opts} ->
      Filename = filename:join(?RRD_IMAGE_DIR, Name ++ ".png"),
      Command = rrd_graph_prefix(Filename, Title, Start, End)
             ++ rrd_graph_def(Name, undefined, average)
             ++ rrd_graph_line(Name, undefined, ?RRD_COLOR_SIMPLE, undefined),
      {ok, _} = errd_server:raw(Server, Command ++ "\n"),
      Filename;
    {collection, Name, _Opts} ->
      Filename = filename:join(?RRD_IMAGE_DIR, Name ++ ".png"),
      Command = rrd_graph_prefix(Filename, Title, Start, End)
             ++ rrd_graph_def(Name, "min", min)
             ++ rrd_graph_def(Name, "avg", last)
             ++ rrd_graph_def(Name, "med", last)
             ++ rrd_graph_def(Name, "max", max)
             ++ rrd_graph_line(Name, "min", ?RRD_COLOR_MIN, "Minimum")
             ++ rrd_graph_line(Name, "avg", ?RRD_COLOR_AVG, "Average")
             ++ rrd_graph_line(Name, "med", ?RRD_COLOR_MED, "Median")
             ++ rrd_graph_line(Name, "max", ?RRD_COLOR_MAX, "Maximum"),
      {ok, _} = errd_server:raw(Server, Command ++ "\n"),
      Filename
  end.

rrd_graph_prefix(FileBasename, Title, Start, End) ->
  aesim_utils:format(
    "graph \"~s\" --start ~b --end ~b -D -E -w ~b -h ~b -t \"~s\" ",
    [FileBasename, Start, End, ?RRD_GRAPH_WIDTH, ?RRD_GRAPH_HEIGHT, Title]).

rrd_graph_tag(Name, undefined) -> Name;
rrd_graph_tag(Name, Postfix) -> Name ++ "_" ++ Postfix.

rrd_graph_cf(average) -> "AVERAGE";
rrd_graph_cf(min) -> "MIN";
rrd_graph_cf(max) -> "MAX";
rrd_graph_cf(last) -> "LAST".

rrd_graph_def(Name, Potfix, CF) ->
  Tag = rrd_graph_tag(Name, Potfix),
  aesim_utils:format("DEF:~s=~s:~s:~s ",
    [Tag, ?RRD_FILE, Tag, rrd_graph_cf(CF)]).

rrd_graph_line(Name, Potfix, Color, undefined) ->
  Tag = rrd_graph_tag(Name, Potfix),
  aesim_utils:format("LINE2:~s~s ", [Tag, Color]);
rrd_graph_line(Name, Potfix, Color, Label) ->
  Tag = rrd_graph_tag(Name, Potfix),
  aesim_utils:format("LINE2:~s~s:\"~s\" ", [Tag, Color, Label]).

rrd_generate_index(Dir, Images) ->
  IndexPath = filename:join(Dir, ?RRD_INDEX_FILE),
  {ok, File} = file:open(IndexPath, [raw , write]),
  lists:foldl(fun(Path, Prefix) ->
    ok = file:write(File, Prefix),
    ok = file:write(File, io_lib:format("<IMG src=\"~s\">~n", [Path])),
    "<BR>\n"
  end, "<HTML><HEAD><TITLE>Simulation</TITLE></HEAD><BODY>\n", Images),
  ok = file:write(File, "</BODY></HTML>\n"),
  IndexPath.

rrd_start_time() ->
  {{Y, M, D}, _} = calendar:now_to_datetime(os:timestamp()),
  [UTC | _] = calendar:local_time_to_universal_time_dst({{Y, M, D}, {0, 0, 0}}),
  calendar:datetime_to_gregorian_seconds(UTC)
    - calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).

rrd_create(#{rrd_server := Server} = State, MaxTime) ->
  StartTime = rrd_start_time(),
  Step = ?UPDATE_INTERVAL div 1000,
  Sources = lists:foldl(fun
    (K, Acc) -> make_rrd_sources(K, Step, Acc)
  end, [], ?RRD_SOURCES),
  Archives = [make_rrd_archive(average, 1, Step, MaxTime div 1000)],
  Command = #rrd_create{
    file = ?RRD_FILE,
    start_time = integer_to_list(StartTime),
    step = ?UPDATE_INTERVAL div 1000,
    ds_defs = Sources,
    rra_defs = Archives
  },
  {ok, _} = errd_server:command(Server, Command),
  State#{rrd_start_time := StartTime}.

rrd_update(#{rrd_server := undefined} = State, _DataPoints) -> State;
rrd_update(State, DataPoints) ->
  #{rrd_server := Server,
    rrd_start_time := StartTime,
    global := GlobalMetrics
  } = State,
  Metrics = reduce_node_metrics(State, maps:to_list(GlobalMetrics)),
  Updates = rrd_collect_ds_updates(Metrics, []),
  lists:foreach(fun(T) ->
    Command = make_rrd_update(StartTime, T, Updates),
    {ok, _} = errd_server:command(Server, Command)
  end, DataPoints),
  State.

rrd_collect_ds_updates(Metrics, Acc) ->
  lists:foldl(fun({K, V}, Acc2) ->
    case k2i(K) of
      undefined -> Acc2;
      {simple, _, Name} ->
        [#rrd_ds_update{name = Name, value = V} | Acc2];
      {collection, _, BaseName} ->
        {Min, Avg, Med, Max} = V,
        [#rrd_ds_update{name = BaseName ++ "_min", value = Min},
         #rrd_ds_update{name = BaseName ++ "_avg", value = Avg},
         #rrd_ds_update{name = BaseName ++ "_med", value = Med},
         #rrd_ds_update{name = BaseName ++ "_max", value = Max}
        | Acc2]
    end
  end, Acc, Metrics).

make_rrd_sources(MetricName, Step, Acc) ->
  Args = aesim_utils:format("~b:0:U", [Step * 2]),
  case k2i(MetricName) of
    undefined -> Acc;
    {simple, Type, Name} ->
      [make_rrd_source(Name, Type, Args) | Acc];
    {collection, Type, Base} ->
      [make_rrd_source(Base ++ "_min", Type, Args),
       make_rrd_source(Base ++ "_avg", Type, Args),
       make_rrd_source(Base ++ "_med", Type, Args),
       make_rrd_source(Base ++ "_max", Type, Args)
      | Acc]
  end.

make_rrd_source(Name, Type, Args) ->
  #rrd_ds{
    name = Name,
    type = Type,
    args = Args,
    % These are not used but makes
    heartbeat = 0,
    min = 0,
    max = 0
  }.

make_rrd_archive(Type, SampleCount, Step, Duration) ->
  Size = Duration div (Step * SampleCount),
  Args = aesim_utils:format("0.5:~b:~b", [SampleCount, Size]),
  #rrd_rra{cf = Type, args = Args}.

make_rrd_update(StartTime, Datapoint, Updates) ->
  #rrd_update{
    file = ?RRD_FILE,
    time = integer_to_list(StartTime + (Datapoint div 1000)),
    updates = Updates
  }.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_rrd_enabled(Sim) -> aesim_config:get(Sim, rrd_enabled).
