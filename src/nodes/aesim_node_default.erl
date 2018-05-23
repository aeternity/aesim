-module(aesim_node_default).

%% @doc Node behaviour of the current epoch p2p protocol (as of 0.14.0)
%%  - Connects to all trusted peers at startup.
%%  - Connects to identified peers with configurable period.
%%  - Prunes node connections based on node id; it keeps outbound connection
%%  from the peer with bigger id.
%%  - Send gossip pings periodically.
%%  - Handle gossip ping responses.
%%  - Optionally limites the number of inbound/outbound connections.
%%  - If the outbound connections are limited, when one fail or is closed
%%   a random peer (not yet connected) is taken from the pool and connected to.

-behaviour(aesim_node).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% Behaviour aesim_node callback functions
-export([parse_options/2]).
-export([node_new/3]).
-export([node_start/4]).
-export([node_accept/4]).
-export([node_handle_event/5]).
-export([node_handle_message/6]).
-export([report/4]).

%=== TYPES =====================================================================

-type state() :: #{
  connecting := boolean(),
  outbound := non_neg_integer(),
  inbound := non_neg_integer()
}.

%=== MACROS ====================================================================

-define(DEFAULT_FIRST_PING_DELAY,          10).
-define(DEFAULT_PING_PERIOD,             "2m").
-define(DEFAULT_PONG_DELAY,                10).
-define(DEFAULT_GOSSIPED_NEIGHBOURS,       30).
-define(DEFAULT_MAX_INBOUND,         infinity).
-define(DEFAULT_MAX_OUTBOUND,        infinity).
-define(DEFAULT_CONNECT_PERIOD,             0).

%=== BEHAVIOUR aesim_node CALLBACK FUNCTIONS ===================================

parse_options(Opts, Sim) ->
  aesim_config:parse(Sim, Opts, [
    {first_ping_delay, time, ?DEFAULT_FIRST_PING_DELAY},
    {ping_period, time, ?DEFAULT_PING_PERIOD},
    {pong_delay, time, ?DEFAULT_PONG_DELAY},
    {gossiped_neighbours, integer, ?DEFAULT_GOSSIPED_NEIGHBOURS},
    {max_inbound, integer_infinity, ?DEFAULT_MAX_INBOUND},
    {max_outbound, integer_infinity, ?DEFAULT_MAX_OUTBOUND},
    {connect_period, integer_infinity, ?DEFAULT_CONNECT_PERIOD}
  ]).

-spec node_new(address_map(), context(), sim()) -> {state(), address(), sim()}.
node_new(AddrMap, _Context, Sim) ->
  State = #{inbound => 0, outbound => 0, connecting => false},
  {State, rand_address(AddrMap), Sim}.

node_start(State, Trusted, Context, Sim) ->
  TrustedIds = [I || {I, _} <- Trusted],
  {State2, Sim2} = lists:foldl(fun(P, {St, Sm}) ->
    {_, St2, Sm2} = maybe_connect(St, P, Context, Sm),
    {St2, Sm2}
  end, {State, Sim}, TrustedIds),
  start_pool_connecting(State2, [], Context, Sim2).

node_accept(State, PeerId, Context, Sim) ->
  case maybe_accept(State, PeerId, Context, Sim) of
    {true, State2, Sim2} -> {accept, State2, Sim2};
    {false, State2, Sim2} -> {reject, State2, Sim2}
  end.

node_handle_event(State, conn_failed, PeerId, Context, Sim) ->
  on_connection_failed(State, PeerId, Context, Sim);
node_handle_event(State, conn_established, {PeerId, ConnRef, ConnType}, Context, Sim) ->
  on_connection_established(State, PeerId, ConnRef, ConnType, Context, Sim);
node_handle_event(State, conn_terminated, {PeerId, ConnRef, ConnType}, Context, Sim) ->
  on_connection_terminated(State, PeerId, ConnRef, ConnType, Context, Sim);
node_handle_event(State, peer_identified, PeerId, Context, Sim) ->
  on_peer_identified(State, PeerId, Context, Sim);
node_handle_event(State, do_pool_connect, Exclude, Context, Sim) ->
  do_pool_connect(State, Exclude, Context, Sim);
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
  {_, Sim2} = aesim_node:async_disconnect(NodeId, ConnRef, Sim),
  {State, Sim2}.

report(_State, _Type, _Context, _Sim) -> #{}.

%=== INTERNAL FUNCTIONS ========================================================

rand_address(AddrMap) ->
  %% Here we could add some logic to ensure there is nodes with the same address
  %% but with different ports.
  O1 = aesim_utils:rand(256),
  O2 = aesim_utils:rand(256),
  O3 = aesim_utils:rand(256),
  O4 = aesim_utils:rand(256),
  Port = aesim_utils:rand(1000, 65536),
  Addr = {{O1, O2, O3, O4}, Port},
  case maps:is_key(Addr, AddrMap) of
    true -> rand_address(AddrMap);
    false -> Addr
  end.

get_neighbours(Exclude, Context, Sim) ->
  #{pool := Pool, peers := Peers} = Context,
  Count = cfg_gossiped_neighbours(Sim),
  {PeerIds, Sim2} = aesim_pool:gossip(Pool, Count, Exclude, Context, Sim),
  {[{I, maps:get(addr, maps:get(I, Peers))} || I <- PeerIds], Sim2}.

select_connection(NodeId, PeerId, ConnRefs, Conns) ->
  %% Keep one of the connections initiated by the node with biggest id
  Initiatores = lists:map(fun(ConnRef) ->
    case aesim_connections:type(Conns, ConnRef) of
      outbound -> {-NodeId, ConnRef};
      inbound -> {-PeerId, ConnRef}
    end
  end, ConnRefs),
  [{_, SelRef} | Rest] = lists:keysort(1, Initiatores),
  {SelRef, [R || {_, R} <- Rest]}.

prune_connections(State, PeerId, ConnRef, Context, Sim) ->
  #{node_id := NodeId, conns := Conns} = Context,
  case aesim_connections:peer_connections(Conns, PeerId) of
    [_] -> {continue, State, Sim};
    ConnRefs ->
      {SelRef, OtherRefs} = select_connection(NodeId, PeerId, ConnRefs, Conns),
      {_, Sim2} = aesim_node:async_disconnect(NodeId, OtherRefs, Sim),
      case SelRef =:= ConnRef of
        true -> {continue, State, Sim2};
        false -> {abort, State, Sim2}
      end
  end.

start_pool_connecting(#{connecting := true} = State, _Exclude, _Context, Sim) ->
  % If we are already connecting, it may be possible we connect again to the
  % same peer because we are ignoring the exclusion list
  {State, Sim};
start_pool_connecting(#{connecting := false} = State, Exclude, Context, Sim) ->
  Sim2 = sched_pool_connect(Exclude, Context, Sim),
  {State#{connecting := true}, Sim2}.

maybe_pool_connect(State, Exclude, Context, Sim) ->
  #{pool := Pool, conns := Conns} = Context,
  ConnectedPeers = aesim_connections:peers(Conns, all),
  %TODO: exclude peers in function of the retry counter
  AllExclude = Exclude ++ ConnectedPeers,
  case aesim_pool:select(Pool, AllExclude, Context, Sim) of
    {undefined, Sim2} ->
      {false, State, Sim2};
    {NewPeerId, Sim2} ->
      maybe_connect(State, NewPeerId, Context, Sim2)
  end.

maybe_connect(State, PeerId, Context, Sim) ->
  #{node_id := NodeId} = Context,
  #{outbound := CurrOutbound} = State,
  case {cfg_max_outbound(Sim), CurrOutbound} of
      {Max, Curr} when Max =:= infinity; Curr < Max ->
        {State2, Sim2} = connect(State, NodeId, PeerId, Sim),
        {true, State2, Sim2};
      {_Max, _Curr} ->
        {false, State, Sim}
  end.

maybe_accept(State, _PeerId, _Context, Sim) ->
  #{inbound := CurrInbound} = State,
  case {cfg_max_inbound(Sim), CurrInbound} of
    {Max, Curr} when Max =:= infinity; Curr < Max ->
      {State2, Sim2} = accept(State, Sim),
      {true, State2, Sim2};
    {_Max, _Curr} ->
      {false, State, Sim}
  end.

connect(State, NodeId, PeerId, Sim) ->
  #{outbound := Outbound} = State,
  {_, Sim2} = aesim_node:async_connect(NodeId, PeerId, Sim),
  {State#{outbound := Outbound + 1}, Sim2}.

accept(State, Sim) ->
  #{inbound := Inbound} = State,
  {State#{inbound := Inbound + 1}, Sim}.

closed(State, Type, Sim) ->
  #{Type := Inbound} = State,
  {State#{Type := Inbound - 1}, Sim}.

%--- EVENT FUNCTIONS -----------------------------------------------------------

sched_pool_connect(Exclude, Context, Sim) ->
  #{self := Self} = Context,
  Delay = cfg_connect_period(Sim),
  {_, Sim2} = aesim_events:post(Delay, Self, do_pool_connect, Exclude, Sim),
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

do_pool_connect(State, Exclude, Context, Sim) ->
  case maybe_pool_connect(State, Exclude, Context, Sim) of
    {false, State2, Sim2} ->
      % There is no peer available; stop connecting
      {State2#{connecting := false}, Sim2};
    {true, State2, Sim2} ->
      Sim3 = sched_pool_connect([], Context, Sim2),
      {State2, Sim3}
  end.

do_ping(State, ConnRef, Context, Sim) ->
  #{node_addr := NodeAddr} = Context,
  {Neighbours, Sim2} = get_neighbours([], Context, Sim),
  {State, send_ping(ConnRef, NodeAddr, Neighbours, Context, Sim2)}.

do_pong(State, ConnRef, Exclude, Context, Sim) ->
  #{node_addr := NodeAddr} = Context,
  {Neighbours, Sim2} = get_neighbours(Exclude, Context, Sim),
  {State, send_pong(ConnRef, NodeAddr, Neighbours, Context, Sim2)}.

on_peer_identified(State, PeerId, Context, Sim) ->
  #{conns := Conns} = Context,
  % Given connection is asynchronous, it is still possible we already requested
  % to connect to the same peer; this will be resolved by connection pruning.
  case aesim_connections:has_connection(Conns, PeerId) of
    false -> start_pool_connecting(State, [], Context, Sim);
    true -> ignore
  end.

on_connection_failed(State, PeerId, Context, Sim) ->
  {State2, Sim2} = closed(State, outbound, Sim),
  start_pool_connecting(State2, [PeerId], Context, Sim2).

on_connection_established(State, PeerId, ConnRef, Type, Context, Sim) ->
  case {Type, prune_connections(State, PeerId, ConnRef, Context, Sim)} of
    {_, {abort, State2, Sim2}} -> {State2, Sim2};
    {inbound, {continue, State2, Sim2}} -> {State2, Sim2};
    {outbound, {continue, State2, Sim2}} ->
      Sim3 = sched_ping(true, ConnRef, Context, Sim2),
      {State2, Sim3}
  end.

on_connection_terminated(State, _PeerId, _ConnRef, inbound, _Context, Sim) ->
  closed(State, inbound, Sim);
on_connection_terminated(State, PeerId, _ConnRef, outbound, Context, Sim) ->
  {State2, Sim2} = closed(State, outbound, Sim),
  start_pool_connecting(State2, [PeerId], Context, Sim2).

%--- MESSAGE FUNCTIONS ---------------------------------------------------------

send_ping(ConnRef, NodeAddr, Neighbours, Context, Sim) ->
  #{node_id := NodeId} = Context,
  Message = {ping, NodeAddr, Neighbours},
  aesim_node:send(NodeId, ConnRef, Message, Sim).

send_pong(ConnRef, NodeAddr, Neighbours, Context, Sim) ->
  #{node_id := NodeId} = Context,
  Message = {pong, NodeAddr, Neighbours},
  aesim_node:send(NodeId, ConnRef, Message, Sim).

got_ping(State, PeerId, ConnRef, PeerAddr, Neighbours, Context, Sim) ->
  #{node_id := NodeId} = Context,
  Exclude = [PeerId | [I || {I, _} <- Neighbours]],
  Source = {PeerId, PeerAddr},
  {_, Sim2} = aesim_node:async_gossip(NodeId, Source, Neighbours, Sim),
  Sim3 = sched_pong(ConnRef, Exclude, Context, Sim2),
  {State, Sim3}.

got_pong(State, PeerId, ConnRef, PeerAddr, Neighbours, Context, Sim) ->
  #{node_id := NodeId} = Context,
  Source = {PeerId, PeerAddr},
  {_, Sim2} = aesim_node:async_gossip(NodeId, Source, Neighbours, Sim),
  Sim3 = sched_ping(false, ConnRef, Context, Sim2),
  {State, Sim3}.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_first_ping_delay(Sim) -> aesim_config:get(Sim, first_ping_delay).

cfg_ping_period(Sim) -> aesim_config:get(Sim, ping_period).

cfg_pong_delay(Sim) -> aesim_config:get(Sim, pong_delay).

cfg_gossiped_neighbours(Sim) -> aesim_config:get(Sim, gossiped_neighbours).

cfg_max_inbound(Sim) -> aesim_config:get(Sim, max_inbound).

cfg_max_outbound(Sim) -> aesim_config:get(Sim, max_outbound).

cfg_connect_period(Sim) -> aesim_config:get(Sim, connect_period).
