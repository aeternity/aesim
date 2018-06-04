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

-callback node_accept(State, PeerId, ConnRef, Context, Sim)
  -> {accept, State, Sim} | {reject, Sim}
  when State :: term(),
       PeerId :: id(),
       ConnRef :: conn_ref(),
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
-export([connections/1]).
-export([pool/1]).
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
-export([async_peer_expired/3]).
-export([send/4]).

%% Event handling functions; only used by aesim_nodes and aesim_connections
-export([route_event/5]).
-export([post_conn_initiated/6]).
-export([async_conn_aborted/5]).
-export([async_conn_established/5]).
-export([async_conn_terminated/5]).
-export([async_conn_failed/4]).

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

connections(#{conns := Conns}) -> Conns.

pool(#{pool := Pool}) -> Pool.

-spec start(state(), neighbours(), sim()) -> {state(), sim()}.
start(State, Trusted, Sim) ->
  #{addr := NodeAddr} = State,
  {State2, Sim2} = lists:foldl(fun({Id, Addr}, {N, S}) ->
    peer_add_trusted(N, Id, Addr, NodeAddr, S)
  end, {State, Sim}, Trusted),
  {State3, Sim3} = pool_init(State2, Trusted, Sim2),
  {State4, Sim4} = node_start(State3, Trusted, Sim3),
  {State4, Sim4}.

-spec connect(state(), id() | [id()], sim()) -> {state(), sim()}.
connect(State, PeerIds, Sim) when is_list(PeerIds) ->
  Params = [{I, make_ref()} || I <- PeerIds],
  do_connect(State, Params, Sim);
connect(State, PeerId, Sim) ->
  do_connect(State, [{PeerId, make_ref()}], Sim).

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

-spec async_connect(id(), id() | [id()], sim()) -> {conn_ref() | [conn_ref()], sim()}.
async_connect(NodeId, PeerIds, Sim) when is_list(PeerIds) ->
  {Result, Params} = lists:foldl(fun(Id, {Res, Par}) ->
    ConnRef = make_ref(),
    {[ConnRef | Res], [{Id, ConnRef} | Par]}
  end, {[], []}, PeerIds),
  {_, Sim2} = post(0, NodeId, do_connect, Params, Sim),
  {Result, Sim2};
async_connect(NodeId, PeerId, Sim) ->
  ConnRef = make_ref(),
  {_, Sim2} = post(0, NodeId, do_connect, [{PeerId, ConnRef}], Sim),
  {ConnRef, Sim2}.

-spec async_disconnect(id(), conn_ref() | [conn_ref()], sim()) -> sim().
async_disconnect(NodeId, ConnRefs, Sim) ->
  {_, Sim2} = post(0, NodeId, do_disconnect, ConnRefs, Sim),
  Sim2.

-spec async_disconnect_peer(id(), id() | [id()], sim()) -> sim().
async_disconnect_peer(NodeId, PeerIds, Sim) ->
  {_, Sim2} = post(0, NodeId, do_disconnect_peer, PeerIds, Sim),
  Sim2.

-spec async_gossip(id(), neighbour(), neighbours(), sim()) -> sim().
async_gossip(NodeId, Source, Neighbours, Sim) ->
  {_, Sim2} = post(0, NodeId, do_gossip, {Source, Neighbours}, Sim),
  Sim2.

-spec async_peer_expired(id(), id(), sim()) -> sim().
async_peer_expired(NodeId, PeerId, Sim) ->
  {_, Sim2} = post(0, NodeId, peer_expired, PeerId, Sim),
  Sim2.

%--- PUBLIC EVENT HANDLING FUNCTIONS -------------------------------------------

-spec post_conn_initiated(delay(), id(), id(), conn_ref(), term(), sim()) -> {event_ref(), sim()}.
post_conn_initiated(Delay, NodeId, PeerId, ConnRef, Opts, Sim) ->
  post(Delay, NodeId, conn_initiated, {PeerId, ConnRef, Opts}, Sim).

-spec async_conn_aborted(id(), id(), conn_ref(), conn_type(), sim()) -> sim().
async_conn_aborted(NodeId, PeerId, ConnRef, ConnType, Sim) ->
  {_, Sim2} = post(0, NodeId, conn_aborted, {PeerId, ConnRef, ConnType}, Sim),
  Sim2.

-spec async_conn_established(id(), id(), conn_ref(), conn_type(), sim()) -> sim().
async_conn_established(NodeId, PeerId, ConnRef, ConnType, Sim) ->
  {_, Sim2} = post(0, NodeId, conn_established, {PeerId, ConnRef, ConnType}, Sim),
  Sim2.

-spec async_conn_terminated(id(), id(), conn_ref(), conn_type(), sim()) -> sim().
async_conn_terminated(NodeId, PeerId, ConnRef, ConnType, Sim) ->
  {_, Sim2} = post(0, NodeId, conn_terminated, {PeerId, ConnRef, ConnType}, Sim),
  Sim2.

-spec async_conn_failed(id(), id(), conn_ref(), sim()) -> sim().
async_conn_failed(NodeId, PeerId, ConnRef, Sim) ->
  {_, Sim2} = post(0, NodeId, conn_failed, {PeerId, ConnRef}, Sim),
  Sim2.

-spec route_event(state(), event_addr(), event_name(), term(), sim()) -> {state(), sim()}.
route_event(State, [], conn_initiated, {PeerId, ConnRef, Opts}, Sim) ->
  on_connection_initiated(State, PeerId, ConnRef, Opts, Sim);
route_event(State, [], conn_aborted, Params, Sim) ->
  forward_event(State, conn_aborted, Params, Sim);
route_event(State, [], conn_established, {PeerId, ConnRef, ConnType}, Sim) ->
  on_connection_established(State, PeerId, ConnRef, ConnType, Sim);
route_event(State, [], conn_terminated, {PeerId, ConnRef, ConnType}, Sim) ->
  on_connection_terminated(State, PeerId, ConnRef, ConnType, Sim);
route_event(State, [], conn_failed, {PeerId, ConnRef}, Sim) ->
  on_connection_failed(State, PeerId, ConnRef, Sim);
route_event(State, [], conn_send, {ConnRef, Msg}, Sim) ->
  on_connection_send(State, ConnRef, Msg, Sim);
route_event(State, [], conn_receive, {ConnRef, Msg}, Sim) ->
  on_connection_receive(State, ConnRef, Msg, Sim);
route_event(State, [], peer_expired, PeerId, Sim) ->
  on_peer_expired(State, PeerId, Sim);
route_event(State, [], do_connect, Params, Sim) ->
  do_connect(State, Params, Sim);
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

do_connect(State, Params, Sim) ->
  PeerIds = [I || {I, _} <- Params],
  % First be sure the peer exists
  {State2, Sim2} = peer_ensure(State, PeerIds, Sim),
  Sim3 = metrics_connection_retry(State2, PeerIds, Sim2),
  {State3, Sim4} = conns_connect(State2, Params, Sim3),
  {State3, Sim4}.


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

%--- METRIC FUNCTIONS ----------------------------------------------------------

metrics_inc(State, Name, Sim) ->
  #{id := NodeId} = State,
  aesim_metrics:inc(NodeId, Name, 1, Sim).

metrics_dec(State, Name, Sim) ->
  #{id := NodeId} = State,
  aesim_metrics:inc(NodeId, Name, -1, Sim).

%% Send the metric connection.retry if relevent
metrics_connection_retry(State, PeerIds, Sim0) when is_list(PeerIds) ->
  lists:foldl(fun(PeerId, Sim) ->
    metrics_connection_retry(State, PeerId, Sim)
  end, Sim0, PeerIds);
metrics_connection_retry(State, PeerId, Sim) ->
  #{peers := Peers} = State,
  #{PeerId := Peer} = Peers,
  case Peer of
    #{retry_count := RetryCount} when RetryCount > 0 ->
      metrics_inc(State, [connections, retry], Sim);
    _ -> Sim
  end.

%--- PRIVATE EVENT HANDLING FUNCTIONS ------------------------------------------

-spec post(non_neg_integer(), id(), atom(), term(), sim()) -> {event_ref(), sim()}.
post(Delay, NodeId, Name, Params, Sim) ->
  aesim_events:post(Delay, [nodes, NodeId], Name, Params, Sim).

on_connection_initiated(State, PeerId, ConnRef, Opts, Sim) ->
  case conns_prepare_accept(State, PeerId, ConnRef, Opts, Sim) of
    {reject, State2, Sim2} ->
      Sim3 = metrics_inc(State2, [connections, rejected], Sim2),
      {State2, Sim3};
    {accept, State2, Data, Sim2} ->
      case node_accept(State2, PeerId, ConnRef, Sim2) of
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
  Sim2 = metrics_inc(State, [connections, established, ConnType], Sim),
  Sim3 = metrics_inc(State, [connections, count, ConnType], Sim2),
  % Update peers in case we didn't know about it yet
  {State2, Sim4} = peer_ensure(State, PeerId, Sim3),
  State3 = peer_connected(State2, PeerId, Time),
  forward_event(State3, conn_established, {PeerId, ConnRef, ConnType}, Sim4).

on_connection_terminated(State, PeerId, ConnRef, ConnType, Sim) ->
  Sim2 = metrics_inc(State, [connections, terminated, ConnType], Sim),
  Sim3 = metrics_dec(State, [connections, count, ConnType], Sim2),
  forward_event(State, conn_terminated, {PeerId, ConnRef, ConnType}, Sim3).

on_connection_failed(State, PeerId, ConnRef, Sim) ->
  #{time := Time} = Sim,
  Sim2 = metrics_inc(State, [connections, failed], Sim),
  State2 = peer_connection_failed(State, PeerId, Time),
  forward_event(State2, conn_failed, {PeerId, ConnRef}, Sim2).

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

on_peer_expired(State, PeerId, Sim) ->
  Sim2 = metrics_inc(State, [peers, expired], Sim),
  {State2, Sim3} = disconnect_peer(State, PeerId, Sim2),
  State3 = peer_expired(State2, PeerId),
  forward_event(State3, peer_expired, PeerId, Sim3).

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
  #{peers := Peers} = State,
  ?assertNot(maps:is_key(PeerId, Peers)),
  Peer = peer_new(default, undefined, undefined, undefined),
  State2 = State#{peers := Peers#{PeerId => Peer}},
  forward_event(State2, peer_added, PeerId, Sim).

% Should only be called before starting a node; it doesn't notify.
peer_add_trusted(State, PeerId, PeerAddr, SourceAddr, Sim) ->
  #{peers := Peers} = State,
  ?assertNot(maps:is_key(PeerId, Peers)),
  Peer = peer_new(trusted, PeerAddr, SourceAddr, undefined),
  {State#{peers := Peers#{PeerId => Peer}}, Sim}.

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
    {ok, #{addr := undefined} = Peer} ->
      % We didn't know the peer address, so we update it, update gossip time
      % and source and notify about the identifier peer.
      Peer2 = Peer#{
        addr := PeerAddr,
        source_addr := SourceAddr,
        gossip_time := Time
      },
      State2 = State#{peers := Peers#{PeerId := Peer2}},
      forward_event(State2, peer_identified, PeerId, Sim);
    {ok, #{addr := PeerAddr} = Peer} ->
      % The address did not change, so we only update gossip time and source
      Peer2 = Peer#{
        source_addr := SourceAddr,
        gossip_time := Time
      },
      State2 = State#{peers := Peers#{PeerId := Peer2}},
      {State2, Sim};
    {ok, _Peer} ->
      % The address changed, but we MUST NOT update it because it may be an
      % attack vector to invalidate good peers. If the address really changed
      % the peer will be removed through normal retry policy.
      % We don't update source and gossip time either to favor eviction policy.
      {State, Sim}
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

peer_expired(State, PeerId) ->
  #{peers := Peers} = State,
  #{PeerId := Peer} = Peers,
  Peer2 = Peer#{conn_time := undefined, retry_count := 0, retry_time := undefined},
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

node_accept(State, PeerId, ConnRef, Sim) ->
  #{sub := Sub} = State,
  Context = node_context(State),
  NodeMod = cfg_node_mod(Sim),
  {Res, Sub2, Sim2} = NodeMod:node_accept(Sub, PeerId, ConnRef, Context, Sim),
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
  {Pool, Sim2} = PoolMod:pool_new(Context, Sim),
  {State#{pool => {PoolMod, Pool}}, Sim2}.

pool_init(State, Trusted, Sim) ->
  Context = pool_context(State),
  #{pool := {PoolMod, Pool}} = State,
  {Pool2, Sim2} = PoolMod:pool_init(Pool, Trusted, Context, Sim),
  {State#{pool => {PoolMod, Pool2}}, Sim2}.

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

conns_connect(State, Params, Sim) when is_list(Params) ->
  lists:foldl(fun({P, R}, {St, Sm}) -> conns_connect(St, P, R, Sm) end,
              {State, Sim}, Params).

conns_connect(State, PeerId, ConnRef, Sim) ->
  #{conns := Conns} = State,
  Context = conns_context(State),
  {Conns2, Sim2} = aesim_connections:connect(Conns, PeerId, ConnRef, Context, Sim),
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
