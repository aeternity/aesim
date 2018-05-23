-module(aesim_node).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== BEHAVIOUR DEFINITION ======================================================

-callback parse_options(Opts, Sim)
  -> Sim
  when Opts :: map(),
       Sim :: sim().

-callback node_new(UsedAddresses, Context, Sim)
  -> {State, Address, Sim}
  when UsedAddresses :: address_map(),
       Context :: context(),
       Sim :: sim(),
       State :: term(),
       Address :: address().

-callback node_start(State, Trusted, Context, Sim)
  -> {State, Sim}
  when State :: term(),
       Trusted :: neighbours(),
       Context :: context(),
       Sim :: sim().

-callback node_accept(State, PeerId, Context, Sim)
  -> {accept, State, Sim} | {reject, Sim}
  when State :: term(),
       PeerId :: id(),
       Context :: context(),
       Sim :: sim().

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
-export([async_connect/3]).
-export([async_disconnect/3]).
-export([async_disconnect_peer/3]).
-export([async_gossip/4]).
-export([send/4]).

%% Event handling functions; only used by aesim_nodes and aesim_connections
-export([route_event/5]).
-export([post_conn_initiated/6]).
-export([post_conn_established/6]).
-export([post_conn_terminated/6]).
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

-spec parse_options(map(), sim()) -> sim().
parse_options(Opts, Sim) ->
  aesim_config:parse(Sim, Opts, [
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
  {State2, Sim2} = node_new(State1, CurrAddrs, Sim),
  {State3, Sim3} = conns_new(State2, Sim2),
  {State4, Sim4} = pool_new(State3, Sim3),
  {State4, Sim4}.

-spec start(state(), neighbours(), sim()) -> {state(), sim()}.
start(State, Trusted, Sim) ->
  #{addr := NodeAddr} = State,
  {State2, Sim2} = lists:foldl(fun({Id, Addr}, {N, S}) ->
    peer_add(N, trusted, Id, Addr, NodeAddr, undefined, S)
  end, {State, Sim}, Trusted),
  node_start(State2, Trusted, Sim2).

-spec connect(state(), id() | [id()], sim()) -> {state(), sim()}.
connect(State, PeerIds, Sim) ->
  % First be sure the peer exists
  {State2, Sim2} = peer_ensure(State, PeerIds, Sim),
  {State3, Sim3} = conns_connect(State2, PeerIds, Sim2),
  {State3, Sim3}.

-spec disconnect(state(), conn_ref() | [conn_ref()], sim()) -> {state(), sim()}.
disconnect(State, ConnRefs, Sim) ->
  conns_disconnect(State, ConnRefs, Sim).

-spec disconnect_peer(state(), id() | [id()], sim()) -> {state(), sim()}.
disconnect_peer(State, PeerIds, Sim) ->
  conns_disconnect_peer(State, PeerIds, Sim).

-spec report(state(), report_type(), sim()) -> map().
report(State, Type, Sim) ->
  #{peers := Peers} = State,
  ConnsReport = conns_report(State, Type, Sim),
  PoolReport = pool_report(State, Type, Sim),
  NodeReport = node_report(State, Type, Sim),
  Report = #{
    known_peers_count => maps:size(Peers),
    pool => PoolReport,
    connections => ConnsReport
  },
  maps:merge(Report, NodeReport).

%--- API FUNCTIONS FOR CALLBACK MODULES ----------------------------------------

-spec async_connect(id(), id() | [id()], sim()) -> {event_ref(), sim()}.
async_connect(NodeId, PeerIds, Sim) ->
  post(0, NodeId, do_connect, PeerIds, Sim).

-spec async_disconnect(id(), conn_ref() | [conn_ref()], sim()) -> {event_ref(), sim()}.
async_disconnect(NodeId, ConnRefs, Sim) ->
  post(0, NodeId, do_disconnect, ConnRefs, Sim).

-spec async_disconnect_peer(id(), id() | [id()], sim()) -> {event_ref(), sim()}.
async_disconnect_peer(NodeId, PeerIds, Sim) ->
  post(0, NodeId, do_disconnect_peer, PeerIds, Sim).

-spec async_gossip(id(), neighbour(), neighbours(), sim()) -> {event_ref(), sim()}.
async_gossip(NodeId, Source, Neighbours, Sim) ->
  post(0, NodeId, do_gossip, {Source, Neighbours}, Sim).

%--- PUBLIC EVENT HANDLING FUNCTIONS -------------------------------------------

-spec post_conn_initiated(delay(), id(), id(), conn_ref(), term(), sim()) -> {event_ref(), sim()}.
post_conn_initiated(Delay, NodeId, PeerId, ConnRef, Opts, Sim) ->
  post(Delay, NodeId, conn_initiated, {PeerId, ConnRef, Opts}, Sim).

-spec post_conn_established(delay(), id(), id(), conn_ref(), conn_type(), sim()) -> {event_ref(), sim()}.
post_conn_established(Delay, NodeId, PeerId, ConnRef, ConnType, Sim) ->
  post(Delay, NodeId, conn_established, {PeerId, ConnRef, ConnType}, Sim).

-spec post_conn_terminated(delay(), id(), id(), conn_ref(), conn_type(), sim()) -> {event_ref(), sim()}.
post_conn_terminated(Delay, NodeId, PeerId, ConnRef, ConnType, Sim) ->
  post(Delay, NodeId, conn_terminated, {PeerId, ConnRef, ConnType}, Sim).

-spec post_conn_failed(delay(), id(), id(), sim()) -> {event_ref(), sim()}.
post_conn_failed(Delay, NodeId, PeerId, Sim) ->
  post(Delay, NodeId, conn_failed, PeerId, Sim).

-spec route_event(state(), event_addr(), event_name(), term(), sim()) -> {state(), sim()}.
route_event(State, [], conn_initiated, {PeerId, ConnRef, Opts}, Sim) ->
  on_connection_initiated(State, PeerId, ConnRef, Opts, Sim);
route_event(State, [], conn_established, {PeerId, ConnRef, ConnType}, Sim) ->
  on_connection_established(State, PeerId, ConnRef, ConnType, Sim);
route_event(State, [], conn_terminated, {PeerId, ConnRef, ConnType}, Sim) ->
  on_connection_terminated(State, PeerId, ConnRef, ConnType, Sim);
route_event(State, [], conn_failed, PeerId, Sim) ->
  on_connection_failed(State, PeerId, Sim);
route_event(State, [], conn_send, {ConnRef, Msg}, Sim) ->
  on_connection_send(State, ConnRef, Msg, Sim);
route_event(State, [], conn_receive, {ConnRef, Msg}, Sim) ->
  on_connection_receive(State, ConnRef, Msg, Sim);
route_event(State, [], do_connect, PeerIds, Sim) ->
  connect(State, PeerIds, Sim);
route_event(State, [], do_disconnect, ConnRefs, Sim) ->
  disconnect(State, ConnRefs, Sim);
route_event(State, [], do_disconnect_peer, PeerIds, Sim) ->
  disconnect_peer(State, PeerIds, Sim);
route_event(State, [], do_gossip, {Source, Neighbours}, Sim) ->
  do_gossip(State, Source, Neighbours, Sim);
route_event(State, [node], Name, Params, Sim) ->
  node_handle_event(State, Name, Params, Sim);
route_event(State, [pool], Name, Params, Sim) ->
  pool_handle_event(State, Name, Params, Sim);
route_event(State, [connections | Rest], Name, Params, Sim) ->
  conns_route_event(State, Rest, Name, Params, Sim);
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

metrics_inc(State, Name, Sim) ->
  #{id := NodeId} = State,
  aesim_metrics:inc(NodeId, Name, 1, Sim).

do_gossip(State, Source, Neighbours, Sim) ->
  Sim2 = metrics_inc(State, [gossip, received], Sim),
  {SourceId, SourceAddr} = Source,
  lists:foldl(fun({PeerId, PeerAddr}, {N, S}) ->
    peer_gossiped(N, SourceId, SourceAddr, PeerId, PeerAddr, S)
  end, {State, Sim2}, [{SourceId, SourceAddr} | Neighbours]).

%% Forward an event to the node and pool callback modules
forward_event(State, Name, Params, Sim) ->
  {State2, Sim2} = pool_handle_event(State, Name, Params, Sim),
  {State3, Sim3} = node_handle_event(State2, Name, Params, Sim2),
  {State3, Sim3}.

%--- PRIVATE EVENT HANDLING FUNCTIONS ------------------------------------------

post(Delay, NodeId, Name, Params, Sim) ->
  aesim_events:post(Delay, [nodes, NodeId], Name, Params, Sim).

on_connection_initiated(State, PeerId, ConnRef, Opts, Sim) ->
  case conns_prepare_accept(State, PeerId, ConnRef, Opts, Sim) of
    {reject, State2, Sim2} ->
      Sim3 = metrics_inc(State2, [connections, rejected], Sim2),
      {State2, Sim3};
    {accept, State2, Data, Sim2} ->
      case node_accept(State2, PeerId, Sim2) of
        {reject, State3, Sim3} ->
          Sim4 = metrics_inc(State3, [connections, rejected], Sim3),
          conns_commit_reject(State3, Data, Sim4);
        {accept, State3, Sim3} ->
          Sim4 = metrics_inc(State3, [connections, accepted], Sim3),
          conns_commit_accept(State3, Data, Sim4)
      end
  end.

on_connection_established(State, PeerId, ConnRef, ConnType, Sim) ->
  #{time := Time} = Sim,
  Sim2 = metrics_inc(State, [connections, established], Sim),
  % Update peers in case we didn't know about it yet
  {State2, Sim3} = peer_ensure(State, PeerId, Sim2),
  State3 = peer_connected(State2, PeerId, Time),
  forward_event(State3, conn_established, {PeerId, ConnRef, ConnType}, Sim3).

on_connection_terminated(State, PeerId, ConnRef, Type, Sim) ->
  Sim2 = metrics_inc(State, [connections, terminated, Type], Sim),
  forward_event(State, conn_terminated, {PeerId, ConnRef, Type}, Sim2).

on_connection_failed(State, PeerId, Sim) ->
  #{time := Time} = Sim,
  Sim2 = metrics_inc(State, [connections, failed], Sim),
  State2 = peer_connection_failed(State, PeerId, Time),
  forward_event(State2, conn_failed, PeerId, Sim2).

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
      node_handle_message(State, PeerId, ConnRef, Msg, Sim);
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

node_new(State, CurrAddrs, Sim) ->
  Context = node_context(State),
  NodeMod = cfg_node_mod(Sim),
  {Sub, Addr, Sim2} = NodeMod:node_new(CurrAddrs, Context, Sim),
  {State#{sub => Sub, addr => Addr}, Sim2}.

node_start(State, Trusted, Sim) ->
  #{sub := Sub} = State,
  Context = node_context(State),
  NodeMod = cfg_node_mod(Sim),
  {Sub2, Sim2} = NodeMod:node_start(Sub, Trusted, Context, Sim),
  {State#{sub := Sub2}, Sim2}.

node_accept(State, PeerId, Sim) ->
  #{sub := Sub} = State,
  Context = node_context(State),
  NodeMod = cfg_node_mod(Sim),
  {Res, Sub2, Sim2} = NodeMod:node_accept(Sub, PeerId, Context, Sim),
  {Res, State#{sub := Sub2}, Sim2}.

node_handle_event(State, Name, Params, Sim) ->
  #{sub := Sub} = State,
  Context = node_context(State),
  NodeMod = cfg_node_mod(Sim),
  case NodeMod:node_handle_event(Sub, Name, Params, Context, Sim) of
    {Sub2, Sim2} -> {State#{sub := Sub2}, Sim2};
    ignore -> {State, Sim}
  end.

node_handle_message(State, PeerId, ConnRef, Msg, Sim) ->
  #{sub := Sub} = State,
  Context = node_context(State),
  NodeMod = cfg_node_mod(Sim),
  case NodeMod:node_handle_message(Sub, PeerId, ConnRef, Msg, Context, Sim) of
    {Sub2, Sim2} -> {State#{sub := Sub2}, Sim2};
    ignore -> {State, Sim}
  end.

node_report(State, Type, Sim) ->
  #{sub := Sub} = State,
  Context = node_context(State),
  NodeMod = cfg_node_mod(Sim),
  NodeMod:report(Sub, Type, Context, Sim).

%--- POOL CALLBACK FUNCTIONS ---------------------------------------------------

pool_new(State, Sim) ->
  Context = pool_context(State),
  PoolMod = cfg_pool_mod(Sim),
  {Sub, Sim2} = PoolMod:pool_new(Context, Sim),
  {State#{pool => {PoolMod, Sub}}, Sim2}.

pool_handle_event(State, Name, Params, Sim) ->
  #{pool := {PoolMod, Pool}} = State,
  Context = pool_context(State),
  case PoolMod:pool_handle_event(Pool, Name, Params, Context, Sim) of
    {Pool2, Sim2} -> {State#{pool := {PoolMod, Pool2}}, Sim2};
    ignore -> {State, Sim}
  end.

pool_report(State, Type, Sim) ->
  #{pool := {PoolMod, Pool}} = State,
  Context = pool_context(State),
  PoolMod:report(Pool, Type, Context, Sim).

%--- CONNECTIONS FUNCTIONS -----------------------------------------------------

conns_new(State, Sim) ->
  Context = conns_context(State),
  {Conns, Sim2} = aesim_connections:new(Context, Sim),
  {State#{conns => Conns}, Sim2}.

conns_connect(State, undefined, Sim) -> {State, Sim};
conns_connect(State, PeerIds, Sim) when is_list(PeerIds) ->
  lists:foldl(fun(P, {St, Sm}) -> conns_connect(St, P, Sm) end,
              {State, Sim}, PeerIds);
conns_connect(State, PeerId, Sim) ->
  #{conns := Conns} = State,
  Context = conns_context(State),
  {Conns2, Sim2} = aesim_connections:connect(Conns, PeerId, Context, Sim),
  {State#{conns => Conns2}, Sim2}.

conns_disconnect(State, undefined, Sim) -> {State, Sim};
conns_disconnect(State, ConnRefs, Sim) when is_list(ConnRefs) ->
  lists:foldl(fun(R, {St, Sm}) -> conns_disconnect(St, R, Sm) end,
              {State, Sim}, ConnRefs);
conns_disconnect(State, ConnRef, Sim) ->
  #{conns := Conns} = State,
  Context = conns_context(State),
  {Conns2, Sim2} = aesim_connections:disconnect(Conns, ConnRef, Context, Sim),
  {State#{conns => Conns2}, Sim2}.

conns_disconnect_peer(State, undefined, Sim) -> {State, Sim};
conns_disconnect_peer(State, PeerIds, Sim) when is_list(PeerIds) ->
  lists:foldl(fun(P, {St, Sm}) -> conns_disconnect_peer(St, P, Sm) end,
              {State, Sim}, PeerIds);
conns_disconnect_peer(State, PeerId, Sim) ->
  #{conns := Conns} = State,
  Context = conns_context(State),
  {Conns2, Sim2} = aesim_connections:disconnect_peer(Conns, PeerId, Context, Sim),
  {State#{conns => Conns2}, Sim2}.

conns_route_event(State, Addr, Name, Params, Sim) ->
  #{conns := Conns} = State,
  Context = conns_context(State),
  {Conns2, Sim2} = aesim_connections:route_event(Conns, Addr, Name, Params, Context, Sim),
  {State#{conns => Conns2}, Sim2}.

conns_report(State, Type, Sim) ->
  #{conns := Conns} = State,
  Context = conns_context(State),
  aesim_connections:report(Conns, Type, Context, Sim).

conns_prepare_accept(State, PeerId, ConnRef, Opts, Sim) ->
  #{conns := Conns} = State,
  Context = conns_context(State),
  case aesim_connections:prepare_accept(Conns, PeerId, ConnRef, Opts, Context, Sim) of
    {accept, Conns2, Data, Sim2} ->
      {accept, State#{conns := Conns2}, Data, Sim2};
    {reject, Conns2, Sim2} ->
      {reject, State#{conns := Conns2}, Sim2}
  end.

conns_commit_accept(State, Data, Sim) ->
  #{conns := Conns} = State,
  Context = conns_context(State),
  {Conns2, Sim2} = aesim_connections:commit_accept(Conns, Data, Context, Sim),
  {State#{conns => Conns2}, Sim2}.

conns_commit_reject(State, Data, Sim) ->
  #{conns := Conns} = State,
  Context = conns_context(State),
  {Conns2, Sim2} = aesim_connections:commit_reject(Conns, Data, Context, Sim),
  {State#{conns => Conns2}, Sim2}.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_node_mod(Sim) -> aesim_config:get(Sim, node_mod).

cfg_pool_mod(Sim) -> aesim_config:get(Sim, pool_mod).
