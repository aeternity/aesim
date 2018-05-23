-module(aesim_nodes).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% API functions
-export([parse_options/2]).
-export([new/1]).
-export([count/1]).
-export([bootstrap/2]).
-export([start_node/2]).
-export([report/3]).

%% API functions for callback modules
-export([sched_start_node/2]).

%% Event handling functions; only used by aesim_simulator
-export([route_event/5]).

%=== MACROS ====================================================================

-define(DEFAULT_BOOTSTRAP_SIZE,    3).
-define(DEFAULT_TRUSTED_COUNT,     2).

%=== TYPES =====================================================================

-type state() :: #{
  next_id := id(),
  trusted := neighbours(),
  addresses := address_map(),
  nodes := #{id() => aesim_node:state()}
}.

-export_type([state/0]).

%=== API FUNCTIONS =============================================================

-spec parse_options(map(), map()) -> map().
parse_options(Config, Opts) ->
  Config2 = Config#{
    bootstrap_size => maps:get(bootstrap_size, Opts, ?DEFAULT_BOOTSTRAP_SIZE),
    trusted_count => maps:get(trusted_count, Opts, ?DEFAULT_TRUSTED_COUNT)
  },
  aesim_node:parse_options(Config2, Opts).

-spec new(sim()) -> {state(), sim()}.
new(Sim) ->
  State = #{
    next_id => 1,
    trusted => [],
    addresses => #{},
    nodes => #{}
  },
  {State, Sim}.

-spec count(state()) -> non_neg_integer().
count(#{nodes := Nodes}) -> maps:size(Nodes).

%% A bootstrap cluster is a fully connected set of nodes where a subset of them
%% are selected as trusted nodes; trusted nodes will be given to new nodes.
-spec bootstrap(state(), sim()) -> {state(), sim()}.
bootstrap(State, Sim) ->
  lager:debug("Bootstrapping cluster..."),
  ClusterSize = cfg_bootstrap_size(Sim),
  % Start all bootstrap nodes
  {State2, Neighbours, Sim2} = lists:foldl(fun(_, {St, Acc, Sm}) ->
    {St2, NodeId, NodeAddr, Sm2} = node_add(St, Sm),
    {St2, [{NodeId, NodeAddr} | Acc], Sm2}
  end, {State, [], Sim}, lists:seq(1, ClusterSize)),
  % Select trusted neighbours
  TrustedCount = cfg_trusted_count(Sim),
  TrustedNeighbours = aesim_utils:rand_pick(TrustedCount, Neighbours),
  State3 = State2#{trusted := TrustedNeighbours},
  % Start all the nodes
  lists:foldl(fun({NodeId, _}, {St, Sm}) ->
    node_start(St, NodeId, Sm)
  end, {State3, Sim2}, Neighbours).

-spec start_node(state(), sim()) -> {state(), sim()}.
start_node(State, Sim) ->
  {State2, NodeId, _NodeAddr,Sim2} = node_add(State, Sim),
  node_start(State2, NodeId, Sim2).

-spec report(state(), report_type(), sim()) -> map().
report(State, Type, Sim) ->
  #{nodes := Nodes} = State,
  NodeReports = [aesim_node:report(N, Type, Sim) || {_, N} <- maps:to_list(Nodes)],
  ConnCount = lists:foldl(fun(R, Acc) ->
    Acc + maps:get(outbound_count, maps:get(connections, R))
  end, 0, NodeReports),
  #{node_count => count(State),
    connection_count => ConnCount,
    nodes => NodeReports}.

%--- API FUNCTIONS FOR CALLBACK MODULES ----------------------------------------

-spec sched_start_node(delay(), sim()) -> {event_ref(), sim()}.
sched_start_node(Delay, Sim) ->
  post(Delay, start_node, [], Sim).

%--- PUBLIC EVENT FUNCTIONS ----------------------------------------------------

-spec route_event(state(), event_addr(), event_name(), term(), sim()) -> {state(), sim()}.
route_event(State, [], start_node, [], Sim) ->
  start_node(State, Sim);
route_event(State, [NodeId | Rest], Name, Params, Sim)
 when is_integer(NodeId) ->
  #{nodes := Nodes} = State,
  case maps:find(NodeId, Nodes) of
    error ->
      lager:warning("Event ~p for unkown node ~p: ~p", [Name, NodeId, Params]),
      {State, Sim};
    {ok, Node} ->
      {Node2, Sim2} = aesim_node:route_event(Node, Rest, Name, Params, Sim),
      Nodes2 = Nodes#{NodeId := Node2},
      {State#{nodes := Nodes2}, Sim2}
  end;
route_event(State, Addr, Name, Params, Sim) ->
  lager:warning("Unexpected node event ~p for ~p: ~p", [Name, Addr, Params]),
  {State, Sim}.

%=== INTERNAL FUNCTIONS ========================================================

node_add(State, Sim) ->
  #{next_id := NextId, nodes := Nodes, addresses := Addrs} = State,
  {Node, Sim2} = aesim_node:new(NextId, Addrs, Sim),
  #{id := NextId, addr := Addr} = Node,
  ?assertNot(maps:is_key(NextId, Nodes)),
  ?assertNot(maps:is_key(Addr, Addrs)),
  Nodes2 = Nodes#{NextId => Node},
  Addrs2 = Addrs#{Addr => NextId},
  State2 = State#{next_id := NextId + 1, nodes := Nodes2, addresses := Addrs2},
  {State2, NextId, Addr, Sim2}.

node_start(State, NodeId, Sim) ->
  #{nodes := Nodes, trusted := AllTrusted} = State,
  #{NodeId := Node} = Nodes,
  Trusted = [{Id, Addr} || {Id, Addr} <- AllTrusted, Id =/= NodeId],
  {Node2, Sim2} = aesim_node:start(Node, Trusted, Sim),
  Nodes2 = Nodes#{NodeId := Node2},
  {State#{nodes := Nodes2}, Sim2}.

%--- PRIVATE EVENT FUNCTIONS ---------------------------------------------------

post(Delay, Name, Params, Sim) ->
  aesim_events:post(Delay, [nodes], Name, Params, Sim).

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_bootstrap_size(Config) -> aesim_config:get(Config, bootstrap_size).

cfg_trusted_count(Config) -> aesim_config:get(Config, trusted_count).