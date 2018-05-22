-module(aesim_node).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== BEHAVIOUR DEFINITION ======================================================

-callback parse_options(Config, Opts)
  -> Config
  when Config :: map(),
       Opts :: map().

-callback node_new(UsedAddresses, Context, Sim)
  -> {State, Address, Sim}
  when UsedAddresses :: address_map(),
       Context :: context(),
       Sim :: sim(),
       State :: term(),
       Address :: address().

-callback node_handle_event(State, Name, Params, Context, Sim)
  -> ignore | {State, Sim}
  when State :: term(),
       Name :: event_name(),
       Params :: term(),
       Context :: context(),
       Sim :: sim().

-callback node_handle_message(State, PeerId, ConnRef, Message, Context, Sim)
  -> ignore | {State, Sim}
  when State :: term(),
       PeerId :: id(),
       ConnRef :: conn_ref(),
       Message :: term(),
       Context :: context(),
       Sim :: sim().

-callback report(State, Type, Context, Sim)
  -> map()
  when State :: term(),
       Type :: report_type(),
       Context :: context(),
       Sim :: sim().

%=== EXPORTS ===================================================================

%% API functions
-export([parse_options/2]).
-export([new/3]).
-export([start/3]).
-export([connect/3]).
-export([disconnect/3]).
-export([disconnect_peer/3]).
-export([report/3]).

%% API functions for callback modules
-export([sched_connect/4]).
-export([sched_disconnect/4]).
-export([sched_disconnect_peer/4]).
-export([sched_gossip/5]).
-export([send/4]).

%% Event handling functions; only used by aesim_nodes and aesim_connections
-export([route_event/5]).
-export([post_conn_established/6]).
-export([post_conn_closed/6]).
-export([post_conn_failed/4]).

%=== MACROS ====================================================================

-define(DEFAULT_NODE_MOD,           aesim_node_default).
-define(DEFAULT_POOL_MOD,            aesim_pool_simple).

%=== TYPES =====================================================================

-type state() :: #{
  id := id(),
  addr := address(),
  peers := peers(),
  pool := pool(),
  conns := aesim_connections:state(),
  sub := term()
}.

-export_type([state/0]).

%=== API FUNCTIONS =============================================================

-spec parse_options(map(), map()) -> map().
parse_options(Config, Opts) ->
  aesim_config:parse(Config, Opts, [
    {node_mod, atom, ?DEFAULT_NODE_MOD},
    {pool_mod, atom, ?DEFAULT_POOL_MOD}
  ], [
    fun aesim_connections:parse_options/2,
    {node_mod, parse_options},
    {pool_mod, parse_options}
  ]).

-spec new(id(), address_map(), sim()) -> {state(), sim()}.
new(NodeId, CurrAddrs, Sim) ->
  State1 = #{id => NodeId, peers => #{}, addr => undefined},
  NodeContext = node_context(State1),
  {Sub, Addr, Sim2} = node_new(CurrAddrs, NodeContext, Sim),
  State2 = State1#{sub => Sub, addr => Addr},
  {Conns, Sim3} = conns_new(conns_context(State2), Sim2),
  State3 = State2#{conns => Conns},
  {Pool, Sim4} = pool_new(pool_context(State3), Sim3),
  lager:debug("Starting node ~w with address ~p...", [NodeId, Addr]),
  {State3#{pool => Pool}, Sim4}.

-spec start(state(), neighbours(), sim()) -> {state(), sim()}.
start(State, Trusted, Sim) ->
  #{addr := NodeAddr} = State,
  lists:foldl(fun({Id, Addr}, {N, S}) ->
    {N2, S2} = peer_add(N, trusted, Id, Addr, NodeAddr, undefined, S),
    connect(N2, Id, S2)
  end, {State, Sim}, Trusted).

-spec connect(state(), id() | [id()], sim()) -> {state(), sim()}.
connect(State, PeerIds, Sim) ->
  #{conns := Conns} = State,
  % First be sure the peer exists
  {State2, Sim2} = peer_ensure(State, PeerIds, Sim),
  {Conns2, Sim3} = conns_connect(Conns, PeerIds, conns_context(State2), Sim2),
  {State2#{conns := Conns2}, Sim3}.

-spec disconnect(state(), conn_ref() | [conn_ref()], sim()) -> {state(), sim()}.
disconnect(State, ConnRefs, Sim) ->
  #{conns := Conns} = State,
  {Conns2, Sim2} = conns_disconnect(Conns, ConnRefs, conns_context(State), Sim),
  {State#{conns := Conns2}, Sim2}.

-spec disconnect_peer(state(), id() | [id()], sim()) -> {state(), sim()}.
disconnect_peer(State, PeerIds, Sim) ->
  #{conns := Conns} = State,
  {Conns2, Sim2} = conns_disconnect_peer(Conns, PeerIds, conns_context(State), Sim),
  State2 = State#{conns := Conns2},
  {State2, Sim2}.

-spec report(state(), report_type(), sim()) -> map().
report(State, Type, Sim) ->
  #{sub := Sub, conns := Conns, pool := Pool, peers := Peers} = State,
  ConnsReport = conns_report(Conns, Type, conns_context(State), Sim),
  PoolReport = pool_report(Pool, Type, pool_context(State), Sim),
  NodeReport = node_report(Sub, Type, node_context(State), Sim),
  Report = #{
    known_peers_count => maps:size(Peers),
    pool => PoolReport,
    connections => ConnsReport
  },
  maps:merge(Report, NodeReport).

%--- API FUNCTIONS FOR CALLBACK MODULES ----------------------------------------

-spec sched_connect(delay(), id(), id() | [id()], sim()) -> {event_ref(), sim()}.
sched_connect(Delay, NodeId, PeerIds, Sim) ->
  post(Delay, NodeId, connect, PeerIds, Sim).

-spec sched_disconnect(delay(), id(), conn_ref() | [conn_ref()], sim()) -> {event_ref(), sim()}.
sched_disconnect(Delay, NodeId, ConnRefs, Sim) ->
  post(Delay, NodeId, disconnect, ConnRefs, Sim).

-spec sched_disconnect_peer(delay(), id(), id() | [id()], sim()) -> {event_ref(), sim()}.
sched_disconnect_peer(Delay, NodeId, PeerIds, Sim) ->
  post(Delay, NodeId, disconnect_peer, PeerIds, Sim).

-spec sched_gossip(delay(), id(), neighbour(), neighbours(), sim()) -> {event_ref(), sim()}.
sched_gossip(Delay, NodeId, Source, Neighbours, Sim) ->
  post(Delay, NodeId, gossip, {Source, Neighbours}, Sim).

%--- PUBLIC EVENT HANDLING FUNCTIONS -------------------------------------------

-spec post_conn_established(delay(), id(), id(), conn_ref(), conn_type(), sim()) -> {event_ref(), sim()}.
post_conn_established(Delay, NodeId, PeerId, ConnRef, ConnType, Sim) ->
  post(Delay, NodeId, conn_established, {PeerId, ConnRef, ConnType}, Sim).

-spec post_conn_closed(delay(), id(), id(), conn_ref(), conn_type(), sim()) -> {event_ref(), sim()}.
post_conn_closed(Delay, NodeId, PeerId, ConnRef, ConnType, Sim) ->
  post(Delay, NodeId, conn_closed, {PeerId, ConnRef, ConnType}, Sim).

-spec post_conn_failed(delay(), id(), id(), sim()) -> {event_ref(), sim()}.
post_conn_failed(Delay, NodeId, PeerId, Sim) ->
  post(Delay, NodeId, conn_failed, PeerId, Sim).

-spec route_event(state(), event_addr(), event_name(), term(), sim()) -> {state(), sim()}.
route_event(State, [], conn_established, {PeerId, ConnRef, ConnType}, Sim) ->
  on_connection_established(State, PeerId, ConnRef, ConnType, Sim);
route_event(State, [], conn_closed, {PeerId, ConnRef, ConnType}, Sim) ->
  on_connection_closed(State, PeerId, ConnRef, ConnType, Sim);
route_event(State, [], conn_failed, PeerId, Sim) ->
  on_connection_failed(State, PeerId, Sim);
route_event(State, [], conn_send, {ConnRef, Msg}, Sim) ->
  on_connection_send(State, ConnRef, Msg, Sim);
route_event(State, [], conn_receive, {ConnRef, Msg}, Sim) ->
  on_connection_receive(State, ConnRef, Msg, Sim);
route_event(State, [], connect, PeerIds, Sim) ->
  connect(State, PeerIds, Sim);
route_event(State, [], disconnect, ConnRefs, Sim) ->
  disconnect(State, ConnRefs, Sim);
route_event(State, [], disconnect_peer, PeerIds, Sim) ->
  disconnect_peer(State, PeerIds, Sim);
route_event(State, [], gossip, {Source, Neighbours}, Sim) ->
  do_gossip(State, Source, Neighbours, Sim);
route_event(State, [node], Name, Params, Sim) ->
  handle_node_event(State, Name, Params, Sim);
route_event(State, [pool], Name, Params, Sim) ->
  handle_pool_event(State, Name, Params, Sim);
route_event(State, [connections | Rest], Name, Params, Sim) ->
  route_conn_event(State, Rest, Name, Params, Sim);
route_event(State, Addr, Name, Params, Sim) ->
  #{id := NodeId} = State,
  lager:warning("Unexpected node ~p event ~p ~p: ~p", [NodeId, Name, Addr, Params]),
  {State, Sim}.

%--- PUBLIC MESSAGE FUNCTIONS --------------------------------------------------

-spec send(id(), conn_ref(), term(), sim()) -> sim().
send(NodeId, ConnRef, Message, Sim) ->
  {_, Sim2} = post(0, NodeId, conn_send, {ConnRef, Message}, Sim),
  Sim2.

%=== INTERNAL FUNCTIONS ========================================================

do_gossip(State, Source, Neighbours, Sim) ->
  {SourceId, SourceAddr} = Source,
  lists:foldl(fun({PeerId, PeerAddr}, {N, S}) ->
    peer_gossiped(N, SourceId, SourceAddr, PeerId, PeerAddr, S)
  end, {State, Sim}, [{SourceId, SourceAddr} | Neighbours]).

handle_node_event(State, Name, Params, Sim) ->
  #{sub := Sub} = State,
  Context = node_context(State),
  {Sub2, Sim2} = node_handle_event(Sub, Name, Params, Context, Sim),
  {State#{sub := Sub2}, Sim2}.

handle_pool_event(State, Name, Params, Sim) ->
  #{pool := Pool} = State,
  Context = pool_context(State),
  {Pool2, Sim2} = pool_handle_event(Pool, Name, Params, Context, Sim),
  {State#{pool := Pool2}, Sim2}.

route_conn_event(State, Addr, Name, Params, Sim) ->
  #{conns := Conns} = State,
  Context = conns_context(State),
  {Conn2, Sim2} = conns_route_event(Conns, Addr, Name, Params, Context, Sim),
  {State#{conns := Conn2}, Sim2}.

%% Forward an event to the node and pool callback modules
forward_event(State, Name, Params, Sim) ->
  {State2, Sim2} = handle_pool_event(State, Name, Params, Sim),
  {State3, Sim3} = handle_node_event(State2, Name, Params, Sim2),
  {State3, Sim3}.

handle_node_message(State, PeerId, ConnRef, Msg, Sim) ->
  #{sub := Sub} = State,
  Context = node_context(State),
  {Sub2, Sim2} = node_handle_message(Sub, PeerId, ConnRef, Msg, Context, Sim),
  {State#{sub := Sub2}, Sim2}.

%--- PRIVATE EVENT HANDLING FUNCTIONS ------------------------------------------

post(Delay, NodeId, Name, Params, Sim) ->
  aesim_events:post(Delay, [nodes, NodeId], Name, Params, Sim).

on_connection_established(State, PeerId, ConnRef, ConnType, Sim) ->
  #{time := Time} = Sim,
  % Update peers in case we didn't know about it yet
  {State2, Sim2} = peer_ensure(State, PeerId, Sim),
  State3 = peer_connected(State2, PeerId, Time),
  forward_event(State3, conn_established, {PeerId, ConnRef, ConnType}, Sim2).

on_connection_closed(State, PeerId, ConnRef, ConnType, Sim) ->
  forward_event(State, conn_closed, {PeerId, ConnRef, ConnType}, Sim).

on_connection_failed(State, PeerId, Sim) ->
  #{time := Time} = Sim,
  State2 = peer_connection_failed(State, PeerId, Time),
  forward_event(State2, conn_failed, PeerId, Sim).

on_connection_send(State, ConnRef, Msg, Sim) ->
  #{conns := Conns} = State,
  case aesim_connections:status(Conns, ConnRef) of
    connected ->
      %TODO: do something with connection callback module ?
      PeerId = aesim_connections:peer(Conns, ConnRef),
      {_, Sim2} = post(0, PeerId, conn_receive, {ConnRef, Msg}, Sim),
      {State, Sim2};
    _ -> {State, Sim}
  end.

on_connection_receive(State, ConnRef, Msg, Sim) ->
  #{conns := Conns} = State,
  case aesim_connections:status(Conns, ConnRef) of
    connected ->
      %TODO: do something with connection callback module ?
      PeerId = aesim_connections:peer(Conns, ConnRef),
      handle_node_message(State, PeerId, ConnRef, Msg, Sim);
    _ -> {State, Sim}
  end.

%--- PEER FUNCTIONS ------------------------------------------------------------

peer_new(PeerType, PeerAddr, SourceAddr, GossipTime) ->
  #{type => PeerType,
    addr => PeerAddr,
    source_addr => SourceAddr,
    gossip_time => GossipTime,
    retry_count => 0,
    retry_time => infinity,
    conn_time => undefined
  }.

peer_add(State, PeerId, Sim) ->
  peer_add(State, default, PeerId, undefined, undefined, undefined, Sim).

peer_add(State, PeerType, PeerId, PeerAddr, SourceAddr, GossipTime, Sim) ->
  #{peers := Peers} = State,
  ?assertNot(maps:is_key(PeerId, Peers)),
  Peer = peer_new(PeerType, PeerAddr, SourceAddr, GossipTime),
  State2 = State#{peers := Peers#{PeerId => Peer}},
  case PeerAddr of
    undefined -> forward_event(State2, peer_added, PeerId, Sim);
    _Addr -> forward_event(State2, peer_identified, PeerId, Sim)
  end.

peer_ensure(State, undefined, Sim) -> {State, Sim};
peer_ensure(State, PeerIds, Sim) when is_list(PeerIds) ->
  lists:foldl(fun(I, {N, S}) -> peer_ensure(N, I, S) end,
              {State, Sim}, PeerIds);
peer_ensure(State, PeerId, Sim) ->
  #{peers := Peers} = State,
  case maps:find(PeerId, Peers) of
    error -> peer_add(State, PeerId, Sim);
    {ok, _Peer} -> {State, Sim}
  end.

peer_gossiped(#{id := Id} = State, _SourceId, _SourceAddr, Id, _PeerAddr, Sim) ->
  %% Ignore the node itself from any gossip sources
  {State, Sim};
peer_gossiped(State, _SourceId, SourceAddr, PeerId, PeerAddr, Sim) ->
  ?assertNot(SourceAddr =:= undefined),
  ?assertNot(PeerAddr =:= undefined),
  #{time := Time} = Sim,
  #{peers := Peers} = State,
  case maps:find(PeerId, Peers) of
    error ->
      Peer = peer_new(default, PeerAddr, SourceAddr, Time),
      State2 = State#{peers := Peers#{PeerId => Peer}},
      forward_event(State2, peer_identified, PeerId, Sim);
    {ok, Peer} ->
      #{addr := OldAddr} = Peer,
      Peer2 = Peer#{
        addr := PeerAddr,
        source_addr := SourceAddr,
        gossip_time := Time
      },
      State2 = State#{peers := Peers#{PeerId := Peer2}},
      %%TODO: No support for nodes that change there address yet...
      case OldAddr of
        PeerAddr -> {State2, Sim};
        undefined ->
          forward_event(State2, peer_identified, PeerId, Sim)
      end
  end.

peer_connected(State, PeerId, Time) ->
  #{peers := Peers} = State,
  #{PeerId := Peer} = Peers,
  Peer2 = Peer#{conn_time := Time, retry_count := 0, retry_time := infinity},
  Peers2 = Peers#{PeerId := Peer2},
  State#{peers := Peers2}.

peer_connection_failed(State, PeerId, Time) ->
  #{peers := Peers} = State,
  #{PeerId := Peer} = Peers,
  #{retry_count := Retry} = Peer,
  Peer2 = Peer#{conn_time := undefined, retry_count := Retry + 1, retry_time := Time},
  Peers2 = Peers#{PeerId := Peer2},
  State#{peers := Peers2}.

%--- CONTEXT FUNCTIONS ---------------------------------------------------------

context(State, Extra, AddrPostfix) ->
  #{id := NodeId, addr := NodeAddr} = State,
  Self = [nodes, NodeId, AddrPostfix],
  Context = maps:with([peers | Extra], State),
  Context#{node_id => NodeId, node_addr => NodeAddr, self => Self}.

pool_context(State) -> context(State, [conns], pool).

node_context(State) -> context(State, [pool, conns], node).

conns_context(State) -> context(State, [pool], connections).

%--- NODE CALLBACK FUNCTIONS ---------------------------------------------------

node_new(CurrAddrs, NodeContext, Sim) ->
  NodeMod = cfg_node_mod(Sim),
  NodeMod:node_new(CurrAddrs, NodeContext, Sim).

node_handle_event(Sub, Name, Params, NodeContext, Sim) ->
  NodeMod = cfg_node_mod(Sim),
  case NodeMod:node_handle_event(Sub, Name, Params, NodeContext, Sim) of
    {Sub2, Sim2} -> {Sub2, Sim2};
    ignore -> {Sub, Sim}
  end.

node_handle_message(Sub, PeerId, ConnRef, Msg, NodeContext, Sim) ->
  NodeMod = cfg_node_mod(Sim),
  case NodeMod:node_handle_message(Sub, PeerId, ConnRef, Msg, NodeContext, Sim) of
    {Sub2, Sim2} -> {Sub2, Sim2};
    ignore -> {Sub, Sim}
  end.

node_report(Sub, Type, NodeContext, Sim) ->
  NodeMod = cfg_node_mod(Sim),
  NodeMod:report(Sub, Type, NodeContext, Sim).

%--- POOL CALLBACK FUNCTIONS ---------------------------------------------------

pool_new(PoolContext, Sim) ->
  PoolMod = cfg_pool_mod(Sim),
  {Sub, Sim2} = PoolMod:pool_new(PoolContext, Sim),
  {{PoolMod, Sub}, Sim2}.

pool_handle_event({PoolMod, Pool}, Name, Params, PoolContext, Sim) ->
  case PoolMod:pool_handle_event(Pool, Name, Params, PoolContext, Sim) of
    {Pool2, Sim2} -> {{PoolMod, Pool2}, Sim2};
    ignore -> {{PoolMod, Pool}, Sim}
  end.

pool_report({PoolMod, Pool}, Type, PoolContext, Sim) ->
  PoolMod:report(Pool, Type, PoolContext, Sim).

%--- CONNECTIONS FUNCTIONS -----------------------------------------------------

conns_new(ConnsContext, Sim) ->
  aesim_connections:new(ConnsContext, Sim).

conns_connect(Conns, undefined, _ConnsContext, Sim) -> {Conns, Sim};
conns_connect(Conns, PeerIds, ConnsContext, Sim) when is_list(PeerIds) ->
  lists:foldl(fun(P, {C, S}) -> conns_connect(C, P, ConnsContext, S) end,
              {Conns, Sim}, PeerIds);
conns_connect(Conns, PeerId, ConnsContext, Sim) ->
  aesim_connections:connect(Conns, PeerId, ConnsContext, Sim).

conns_disconnect(Conns, undefined, _ConnsContext, Sim) -> {Conns, Sim};
conns_disconnect(Conns, ConnRefs, ConnsContext, Sim) when is_list(ConnRefs) ->
  lists:foldl(fun(R, {C, S}) -> conns_disconnect(C, R, ConnsContext, S) end,
              {Conns, Sim}, ConnRefs);
conns_disconnect(Conns, ConnRef, ConnsContext, Sim) ->
  aesim_connections:disconnect(Conns, ConnRef, ConnsContext, Sim).

conns_disconnect_peer(Conns, undefined, _ConnsContext, Sim) -> {Conns, Sim};
conns_disconnect_peer(Conns, PeerIds, ConnsContext, Sim) when is_list(PeerIds) ->
  lists:foldl(fun(P, {C, S}) -> conns_disconnect_peer(C, P, ConnsContext, S) end,
              {Conns, Sim}, PeerIds);
conns_disconnect_peer(Conns, PeerId, ConnsContext, Sim) ->
  aesim_connections:disconnect_peer(Conns, PeerId, ConnsContext, Sim).

conns_route_event(Conns, Addr, Name, Params, ConnsContext, Sim) ->
  aesim_connections:route_event(Conns, Addr, Name, Params, ConnsContext, Sim).

conns_report(Conns, Type, ConnsContext, Sim) ->
  aesim_connections:report(Conns, Type, ConnsContext, Sim).

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_node_mod(Config) -> aesim_config:get(Config, node_mod).

cfg_pool_mod(Config) -> aesim_config:get(Config, pool_mod).
