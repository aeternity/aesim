-module(aesim_node_default).

%% @doc Node behaviour of the current epoch p2p protocol (as of 0.14.0)
%%  - Connects to all trusted peers at startup.
%%  - Connects to identified peers with configurable period.
%%  - Prunes node connections based on node id; it keeps outbound connection
%%  from the peer with smaller `md5(id)` (for better distribution).
%%  - Send gossip pings periodically.
%%  - Handle gossip ping responses.
%%  - Optionally limites the number of inbound/outbound connections.
%%  - If the outbound connections are limited, when one fail or is closed
%%  a random peer (not yet connected) is taken from the pool and connected to.
%%  - Optionally limit the outbound connections to one connection per address
%%  group.
%%  - Accepts a file as option containing a list of IP range terms to generate
%%  the IP from.

-behaviour(aesim_node).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% Behaviour aesim_node callback functions
-export([parse_options/2]).
-export([node_new/4]).
-export([node_start/4]).
-export([node_accept/5]).
-export([node_handle_event/5]).
-export([node_handle_message/6]).
-export([report/4]).

%=== TYPES =====================================================================

-type state() :: #{
  connecting := boolean(),
  temporary := #{conn_ref() => true},
  outbound := #{conn_ref() => address_group()},
  inbound := non_neg_integer()
}.

%=== MACROS ====================================================================

-define(DEFAULT_FIRST_PING_DELAY,           100).
-define(DEFAULT_PING_PERIOD,               "2m").
-define(DEFAULT_PONG_DELAY,                 100).
-define(DEFAULT_GOSSIPED_NEIGHBOURS,         30).
-define(DEFAULT_MAX_INBOUND,           infinity).
-define(DEFAULT_SOFT_MAX_INBOUND,      infinity).
-define(DEFAULT_MAX_OUTBOUND,          infinity).
-define(DEFAULT_CONNECT_PERIOD,               0).
-define(DEFAULT_LIMIT_OUTBOUND_GROUPS,    false).

%=== BEHAVIOUR aesim_node CALLBACK FUNCTIONS ===================================

parse_options(Opts, Sim) ->
  aesim_config:parse(Sim, Opts, [
    {first_ping_delay, time, ?DEFAULT_FIRST_PING_DELAY},
    {ping_period, time, ?DEFAULT_PING_PERIOD},
    {pong_delay, time, ?DEFAULT_PONG_DELAY},
    {gossiped_neighbours, integer, ?DEFAULT_GOSSIPED_NEIGHBOURS},
    {max_inbound, integer_infinity, ?DEFAULT_MAX_INBOUND},
    {soft_max_inbound, integer_infinity, ?DEFAULT_SOFT_MAX_INBOUND},
    {max_outbound, integer_infinity, ?DEFAULT_MAX_OUTBOUND},
    {connect_period, integer_infinity, ?DEFAULT_CONNECT_PERIOD},
    {limit_outbound_groups, boolean, ?DEFAULT_LIMIT_OUTBOUND_GROUPS}
  ]).

-spec node_new(undefined | address_ranges(), address_map(), context(), sim()) -> {state(), address(), sim()}.
node_new(AddrRanges, AddrMap, _Context, Sim) ->
  State = #{
    temporary => #{},
    inbound => 0,
    outbound => #{},
    connecting => false
  },
  {State, rand_address(AddrRanges, AddrMap), Sim}.

%% Connects to all trusted peers and starts periodical connection to pooled peers.
node_start(State, Trusted, Context, Sim) ->
  TrustedIds = [I || {I, _} <- Trusted],
  {State2, Sim2} = lists:foldl(fun(P, {St, Sm}) ->
    {_, St2, Sm2} = maybe_connect(St, P, Context, Sm),
    {St2, Sm2}
  end, {State, Sim}, TrustedIds),
  start_pool_connecting(State2, Context, Sim2).

%% Accepts all connections up to the configured maximum number of inbound connections.
node_accept(State, PeerId, ConnRef, Context, Sim) ->
  case maybe_accept(State, PeerId, ConnRef, Context, Sim) of
    {true, State2, Sim2} -> {accept, State2, Sim2};
    {false, State2, Sim2} -> {reject, State2, Sim2}
  end.

node_handle_event(State, conn_failed, {PeerId, ConnRef}, Context, Sim) ->
  on_connection_failed(State, PeerId, ConnRef, Context, Sim);
node_handle_event(State, conn_aborted, {PeerId, ConnRef, ConnType}, Context, Sim) ->
  on_connection_aborted(State, PeerId, ConnRef, ConnType, Context, Sim);
node_handle_event(State, conn_established, {PeerId, ConnRef, ConnType}, Context, Sim) ->
  on_connection_established(State, PeerId, ConnRef, ConnType, Context, Sim);
node_handle_event(State, conn_terminated, {PeerId, ConnRef, ConnType}, Context, Sim) ->
  on_connection_terminated(State, PeerId, ConnRef, ConnType, Context, Sim);
node_handle_event(State, peer_identified, PeerId, Context, Sim) ->
  on_peer_identified(State, PeerId, Context, Sim);
node_handle_event(State, do_pool_connect, [], Context, Sim) ->
  do_pool_connect(State, Context, Sim);
node_handle_event(State, do_ping, ConnRef, Context, Sim) ->
  do_ping(State, ConnRef, Context, Sim);
node_handle_event(State, do_pong, {ConnRef, Exclude}, Context, Sim) ->
  do_pong(State, ConnRef, Exclude, Context, Sim);
node_handle_event(_State, _Name, _Params, _Context, _Sim) -> ignore.

node_handle_message(State, PeerId, ConnRef, {ping, PeerAddr, Neighbours}, Context, Sim) ->
  got_ping(State, PeerId, ConnRef, PeerAddr, Neighbours, Context, Sim);
node_handle_message(State, PeerId, ConnRef, {pong, PeerAddr, Neighbours}, Context, Sim) ->
  got_pong(State, PeerId, ConnRef, PeerAddr, Neighbours, Context, Sim);
node_handle_message(State, PeerId, ConnRef, Message, Context, Sim) ->
  #{node_id := NodeId} = Context,
  lager:warning("Unexpected message from node ~w to node ~w: ~p",
                [PeerId, NodeId, Message]),
  Sim2 = aesim_node:async_disconnect(NodeId, ConnRef, Sim),
  {State, Sim2}.

report(_State, _Type, _Context, _Sim) -> #{}.

%=== INTERNAL FUNCTIONS ========================================================

rand_address(undefined, AddrMap) ->
  %% Here we could add some logic to ensure there is nodes
  %% with the same address but with different ports.
  O1 = aesim_utils:rand(256),
  O2 = aesim_utils:rand(256),
  O3 = aesim_utils:rand(256),
  O4 = aesim_utils:rand(256),
  Port = aesim_utils:rand(1000, 65536),
  Addr = {{O1, O2, O3, O4}, Port},
  case maps:is_key(Addr, AddrMap) of
    true -> rand_address(undefined, AddrMap);
    false -> Addr
  end;
rand_address(AddrRanges, AddrMap) ->
  {BaseBin, Mask} = aesim_utils:rand_pick(AddrRanges),
  RandMask = (1 bsl (32 - Mask)) - 1,
  BaseMask = (1 bsl 32) - 1 - RandMask,
  <<RandNum:32/unsigned-big-integer>> = crypto:strong_rand_bytes(4),
  <<BaseNum:32/unsigned-big-integer>> = BaseBin,
  AddrNum = (BaseNum band BaseMask) + (RandNum band RandMask),
  <<A:8, B:8, C:8, D:8>> = <<AddrNum:32/unsigned-big-integer>>,
  Port = aesim_utils:rand(1000, 65536),
  Addr = {{A, B, C, D}, Port},
  case maps:is_key(Addr, AddrMap) of
    true -> rand_address(AddrRanges, AddrMap);
    false -> Addr
  end.

%% Gets a list of peer from the pool.
get_neighbours(Exclude, Context, Sim) ->
  #{pool := Pool, peers := Peers} = Context,
  Count = cfg_gossiped_neighbours(Sim),
  {PeerIds, Sim2} = aesim_pool:gossip(Pool, Count, Exclude, Context, Sim),
  {[{I, maps:get(addr, maps:get(I, Peers))} || I <- PeerIds], Sim2}.

%% Selects a single connection from a list in a predictable way.
select_connection(NodeId, PeerId, ConnRefs, Conns) ->
  %% Keep one of the connections initiated by the node with biggest id
  Initiatores = lists:map(fun(ConnRef) ->
    case aesim_connections:type(Conns, ConnRef) of
      outbound -> {crypto:hash(md5, integer_to_list(NodeId)), ConnRef};
      inbound -> {crypto:hash(md5, integer_to_list(PeerId)), ConnRef}
    end
  end, ConnRefs),
  [{_, SelRef} | Rest] = lists:keysort(1, Initiatores),
  {SelRef, [R || {_, R} <- Rest]}.

%% Prunes the connection ot a given peer.
%% One is selected and the other ones are disconnected.
prune_connections(State, PeerId, ConnRef, Context, Sim) ->
  #{node_id := NodeId, conns := Conns} = Context,
  case aesim_connections:peer_connections(Conns, PeerId) of
    [_] -> {continue, State, Sim};
    ConnRefs ->
      ?assert(length(ConnRefs) > 0),
      {SelRef, OtherRefs} = select_connection(NodeId, PeerId, ConnRefs, Conns),
      Sim2 = aesim_metrics:inc(NodeId, [connections, pruned], length(OtherRefs), Sim),
      Sim3 = aesim_node:async_disconnect(NodeId, OtherRefs, Sim2),
      case SelRef =:= ConnRef of
        true -> {continue, State, Sim3};
        false -> {abort, State, Sim3}
      end
  end.

%% Starts the periodic task that tries to connect to a peer taken froim the pool.
start_pool_connecting(#{connecting := true} = State, _Context, Sim) ->
  % If we are already connecting, it may be possible we connect again to the
  % same peer because we are ignoring the exclusion list
  {State, Sim};
start_pool_connecting(#{connecting := false} = State, Context, Sim) ->
  Sim2 = sched_pool_connect(undefined, Context, Sim),
  {State#{connecting := true}, Sim2}.

%% Connects to a peer selected from the pool if possible.
%% The pool can respond with the next time a peer will be available due
%% to the retry policy; it is used it to schedule the next try.
maybe_pool_connect(State, Context, Sim) ->
  #{outbound := Outbound} = State,
  #{time := Now} = Sim,
  #{pool := Pool, conns := Conns} = Context,
  ConnectedPeers = aesim_connections:peers(Conns, all),
  ExcludeGroups = case cfg_limit_outbound_groups(Sim) of
    false -> [];
    true -> maps:values(Outbound)
  end,
  case aesim_pool:select(Pool, ConnectedPeers, ExcludeGroups, Context, Sim) of
    {unavailable, Sim2} ->
      {false, State, Sim2};
    {retry, NextTry, Sim2} ->
      {true, NextTry - Now, State, Sim2};
    {selected, NewPeerId, Sim2} ->
      maybe_connect(State, NewPeerId, Context, Sim2)
  end.

%% Connects to a peer if the maximum number of outbound connections is not reached.
maybe_connect(State, PeerId, Context, Sim) ->
  #{outbound := CurrOutbound} = State,
  case {cfg_max_outbound(Sim), maps:size(CurrOutbound)} of
      {Max, Curr} when Max =:= infinity; Curr < Max ->
        {State2, Sim2} = connect(State, PeerId, Context, Sim),
        {true, State2, Sim2};
      {_Max, _Curr} ->
        {false, State, Sim}
  end.

%% Accept a peer connection if the maximum number of inbound connections is not reached.
maybe_accept(State, _PeerId, ConnRef, _Context, Sim) ->
  #{inbound := CurrInbound} = State,
  SoftMax = cfg_soft_max_inbound(Sim),
  IsSoft = (SoftMax =/= infinity) andalso (CurrInbound >= SoftMax),
  case {cfg_max_inbound(Sim), CurrInbound} of
    {Max, Curr} when Max =:= infinity; Curr < Max ->
      {State2, Sim2} = accept(State, ConnRef, IsSoft, Sim),
      {true, State2, Sim2};
    {_Max, _Curr} ->
      {false, State, Sim}
  end.

connect(State, PeerId, Context, Sim) ->
  #{outbound := Outbound} = State,
  #{node_id := NodeId, peers := Peers} = Context,
  ?assert(maps:is_key(PeerId, Peers)),
  #{PeerId := Peer} = Peers,
  ?assertNotEqual(undefined, maps:get(addr, Peer)),
  #{addr := PeerAddr} = Peer,
  PeerGroup = aesim_utils:address_group(PeerAddr),
  {ConnRef, Sim2} = aesim_node:async_connect(NodeId, PeerId, Sim),
  {State#{outbound := Outbound#{ConnRef => PeerGroup}}, Sim2}.

accept(State, ConnRef, true, Sim) ->
  #{inbound := Inbound, temporary := Temp} = State,
  {State#{inbound := Inbound + 1, temporary := Temp#{ConnRef => true}}, Sim};
accept(State, _ConnRef, false, Sim) ->
  #{inbound := Inbound} = State,
  {State#{inbound := Inbound + 1}, Sim}.

closed(State, _ConnRef, inbound, Sim) ->
  #{inbound := Inbound} = State,
  {State#{inbound := Inbound - 1}, Sim};
closed(State, ConnRef, outbound, Sim) ->
  #{outbound := Outbound} = State,
  {State#{outbound := maps:remove(ConnRef, Outbound)}, Sim}.

%--- EVENT FUNCTIONS -----------------------------------------------------------

sched_pool_connect(undefined, Context, Sim) ->
  #{self := Self} = Context,
  Delay = cfg_connect_period(Sim),
  {_, Sim2} = aesim_events:post(Delay, Self, do_pool_connect, [], Sim),
  Sim2;
sched_pool_connect(MinDelay, Context, Sim) ->
  #{self := Self} = Context,
  Delay = max(MinDelay, cfg_connect_period(Sim)),
  {_, Sim2} = aesim_events:post(Delay, Self, do_pool_connect, [], Sim),
  Sim2.

sched_ping(true, ConnRef, Context, Sim) ->
  #{self := Self} = Context,
  Delay = cfg_first_ping_delay(Sim),
  {_, Sim2} = aesim_events:post(Delay, Self, do_ping, ConnRef, Sim),
  Sim2;
sched_ping(false, ConnRef, Context, Sim) ->
  #{self := Self} = Context,
  Delay = cfg_ping_period(Sim),
  {_, Sim2} = aesim_events:post(Delay, Self, do_ping, ConnRef, Sim),
  Sim2.

sched_pong(ConnRef, Exclude, Context, Sim) ->
  #{self := Self} = Context,
  Delay = cfg_pong_delay(Sim),
  {_, Sim2} = aesim_events:post(Delay, Self, do_pong, {ConnRef, Exclude}, Sim),
  Sim2.

%% Try connecting to a pooled peer and schedule the next try if relevent.
do_pool_connect(State, Context, Sim) ->
  case maybe_pool_connect(State, Context, Sim) of
    {false, State2, Sim2} ->
      % There is no peer available; stop connecting
      {State2#{connecting := false}, Sim2};
    {true, State2, Sim2} ->
      Sim3 = sched_pool_connect(undefined , Context, Sim2),
      {State2, Sim3};
    {true, MinDelay, State2, Sim2} ->
      Sim3 = sched_pool_connect(MinDelay, Context, Sim2),
      {State2, Sim3}
  end.

%% Prepares and send a ping message through a connection.
do_ping(State, ConnRef, Context, Sim) ->
  #{node_addr := NodeAddr} = Context,
  {Neighbours, Sim2} = get_neighbours([], Context, Sim),
  {State, send_ping(ConnRef, NodeAddr, Neighbours, Context, Sim2)}.

%% Prepares and sends a ping reponse message through a connection.
do_pong(State, ConnRef, Exclude, Context, Sim) ->
  #{temporary := Temp} = State,
  #{node_id := NodeId, node_addr := NodeAddr} = Context,
  {Neighbours, Sim2} = get_neighbours(Exclude, Context, Sim),
  Sim3 = send_pong(ConnRef, NodeAddr, Neighbours, Context, Sim2),
  % if the connection is temporary, we disconnect.
  case maps:take(ConnRef, Temp) of
    error -> {State, Sim3};
    {true, Temp2} ->
      Sim4 = aesim_node:async_disconnect(NodeId, ConnRef, Sim3),
      {State#{temporary := Temp2}, Sim4}
  end.

on_peer_identified(State, PeerId, Context, Sim) ->
  #{conns := Conns} = Context,
  % Given connection is asynchronous, it is still possible we already requested
  % to connect to the same peer; this will be resolved by connection pruning.
  case aesim_connections:has_connection(Conns, PeerId) of
    false -> start_pool_connecting(State, Context, Sim);
    true -> ignore
  end.

on_connection_failed(State, _PeerId, ConnRef, Context, Sim) ->
  {State2, Sim2} = closed(State, ConnRef, outbound, Sim),
  start_pool_connecting(State2, Context, Sim2).

on_connection_aborted(State, _PeerId, ConnRef, ConnType, _Context, Sim) ->
  closed(State, ConnRef, ConnType, Sim).

%% Prunes the connections, and send a ping message if it is an outbound connection.
%% The connection may be aborted if the connection itself got pruned away.
on_connection_established(State, PeerId, ConnRef, ConnType, Context, Sim) ->
  case {ConnType, prune_connections(State, PeerId, ConnRef, Context, Sim)} of
    {_, {abort, State2, Sim2}} -> {State2, Sim2};
    {inbound, {continue, State2, Sim2}} -> {State2, Sim2};
    {outbound, {continue, State2, Sim2}} ->
      Sim3 = sched_ping(true, ConnRef, Context, Sim2),
      {State2, Sim3}
  end.

on_connection_terminated(State, _PeerId, ConnRef, inbound, _Context, Sim) ->
  closed(State, ConnRef, inbound, Sim);
on_connection_terminated(State, _PeerId, ConnRef, outbound, Context, Sim) ->
  {State2, Sim2} = closed(State, ConnRef, outbound, Sim),
  start_pool_connecting(State2, Context, Sim2).

%--- MESSAGE FUNCTIONS ---------------------------------------------------------

send_ping(ConnRef, NodeAddr, Neighbours, Context, Sim) ->
  #{node_id := NodeId} = Context,
  Message = {ping, NodeAddr, Neighbours},
  aesim_node:send(NodeId, ConnRef, Message, Sim).

send_pong(ConnRef, NodeAddr, Neighbours, Context, Sim) ->
  #{node_id := NodeId} = Context,
  Message = {pong, NodeAddr, Neighbours},
  aesim_node:send(NodeId, ConnRef, Message, Sim).

%% Handles ping messages and schedule a response.
got_ping(State, PeerId, ConnRef, PeerAddr, Neighbours, Context, Sim) ->
  #{node_id := NodeId} = Context,
  Exclude = [PeerId | [I || {I, _} <- Neighbours]],
  Source = {PeerId, PeerAddr},
  Sim2 = aesim_node:async_gossip(NodeId, Source, Neighbours, Sim),
  Sim3 = sched_pong(ConnRef, Exclude, Context, Sim2),
  {State, Sim3}.

%% Handles ping message responses and schedule the next ping message.
got_pong(State, PeerId, ConnRef, PeerAddr, Neighbours, Context, Sim) ->
  #{node_id := NodeId} = Context,
  Source = {PeerId, PeerAddr},
  Sim2 = aesim_node:async_gossip(NodeId, Source, Neighbours, Sim),
  Sim3 = sched_ping(false, ConnRef, Context, Sim2),
  {State, Sim3}.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_first_ping_delay(Sim) -> aesim_config:get(Sim, first_ping_delay).

cfg_ping_period(Sim) -> aesim_config:get(Sim, ping_period).

cfg_pong_delay(Sim) -> aesim_config:get(Sim, pong_delay).

cfg_gossiped_neighbours(Sim) -> aesim_config:get(Sim, gossiped_neighbours).

cfg_max_inbound(Sim) -> aesim_config:get(Sim, max_inbound).

cfg_soft_max_inbound(Sim) -> aesim_config:get(Sim, soft_max_inbound).

cfg_max_outbound(Sim) -> aesim_config:get(Sim, max_outbound).

cfg_connect_period(Sim) -> aesim_config:get(Sim, connect_period).

cfg_limit_outbound_groups(Sim) -> aesim_config:get(Sim, limit_outbound_groups).
