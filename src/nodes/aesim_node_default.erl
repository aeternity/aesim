-module(aesim_node_default).

%% @doc Default node behaviour.
%%  - Prunes node connections based on node id; it keeps outbound connection from
%%  the peers with bigger id.
%%  - Send gossip pings periodically.
%%  - Handle gossip ping responses.

-behaviour(aesim_node).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% Behaviour aesim_node callback functions
-export([parse_options/2]).
-export([node_new/3]).
-export([node_handle_event/5]).
-export([node_handle_message/6]).
-export([report/4]).

%=== MACROS ====================================================================

-define(DEFAULT_FIRST_PING_DELAY,        10).
-define(DEFAULT_PING_PERIOD,         120000).
-define(DEFAULT_PONG_DELAY,              10).
-define(DEFAULT_GOSSIPED_NEIGHBOURS,     30).

%=== BEHAVIOUR aesim_node CALLBACK FUNCTIONS ===================================

parse_options(Config, Opts) ->
  aesim_config:parse(Config, Opts, [
    {first_ping_delay, time, ?DEFAULT_FIRST_PING_DELAY},
    {ping_period, time, ?DEFAULT_PING_PERIOD},
    {pong_delay, time, ?DEFAULT_PONG_DELAY},
    {gossiped_neighbours, integer, ?DEFAULT_GOSSIPED_NEIGHBOURS}
  ]).

node_new(AddrMap, _Context, Sim) ->
  {#{}, rand_address(AddrMap), Sim}.

node_handle_event(State, conn_established, {PeerId, ConnRef, ConnType}, Context, Sim) ->
  on_connection_established(State, PeerId, ConnRef, ConnType, Context, Sim);
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
  {_, Sim2} = aesim_node:sched_disconnect(0, NodeId, ConnRef, Sim),
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
  {PeerIds, Sim2} = aesim_pool:select(Pool, Count, Exclude, Context, Sim),
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

chain(State, _PeerId, _Context, Sim, []) -> {State, Sim};
chain(State, PeerId, Context, Sim, [F | Fs]) ->
  case F(State, PeerId, Context, Sim) of
    {continue, State2, Sim2} -> chain(State2, PeerId, Context, Sim2, Fs);
    {abort, State2, Sim2} -> {State2, Sim2}
  end.

%--- EVENT FUNCTIONS -----------------------------------------------------------

sched_ping(Delay, ConnRef, Context, Sim) ->
  #{self := Self} = Context,
  {_, Sim2} = aesim_events:post(Delay, Self, do_ping, ConnRef, Sim),
  Sim2.

sched_pong(Delay, ConnRef, Exclude, Context, Sim) ->
  #{self := Self} = Context,
  {_, Sim2} = aesim_events:post(Delay, Self, do_pong, {ConnRef, Exclude}, Sim),
  Sim2.

do_ping(State, ConnRef, Context, Sim) ->
  #{node_addr := NodeAddr} = Context,
  {Neighbours, Sim2} = get_neighbours([], Context, Sim),
  {State, send_ping(ConnRef, NodeAddr, Neighbours, Context, Sim2)}.

do_pong(State, ConnRef, Exclude, Context, Sim) ->
  #{node_addr := NodeAddr} = Context,
  {Neighbours, Sim2} = get_neighbours(Exclude, Context, Sim),
  {State, send_pong(ConnRef, NodeAddr, Neighbours, Context, Sim2)}.

on_connection_established(State, PeerId, ConnRef, outbound, Context, Sim) ->
  chain(State, {PeerId, ConnRef}, Context, Sim, [
    fun chain_prune_connections/4,
    fun chain_schedule_first_ping/4
  ]);
on_connection_established(State, PeerId, ConnRef, inbound, Context, Sim) ->
  chain(State, {PeerId, ConnRef}, Context, Sim, [
    fun chain_prune_connections/4
  ]).

chain_prune_connections(State, {PeerId, ConnRef}, Context, Sim) ->
  #{node_id := NodeId, conns := Conns} = Context,
  case aesim_connections:peer_connections(Conns, PeerId) of
    [_] -> {continue, State, Sim};
    ConnRefs ->
      {SelRef, OtherRefs} = select_connection(NodeId, PeerId, ConnRefs, Conns),
      {_, Sim2} = aesim_node:sched_disconnect(0, NodeId, OtherRefs, Sim),
      case SelRef =:= ConnRef of
        true -> {continue, State, Sim2};
        false -> {abort, State, Sim2}
      end
  end.

chain_schedule_first_ping(State, {_PeerId, ConnRef}, Context, Sim) ->
  Sim2 = sched_ping(cfg_first_ping_delay(Sim), ConnRef, Context, Sim),
  {continue, State, Sim2}.

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
  {_, Sim2} = aesim_node:sched_gossip(0, NodeId, Source, Neighbours, Sim),
  Sim3 = sched_pong(cfg_pong_delay(Sim), ConnRef, Exclude, Context, Sim2),
  {State, Sim3}.

got_pong(State, PeerId, ConnRef, PeerAddr, Neighbours, Context, Sim) ->
  #{node_id := NodeId} = Context,
  Source = {PeerId, PeerAddr},
  {_, Sim2} = aesim_node:sched_gossip(0, NodeId, Source, Neighbours, Sim),
  Sim3 = sched_ping(cfg_ping_period(Sim), ConnRef, Context, Sim2),
  {State, Sim3}.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_first_ping_delay(Config) -> aesim_config:get(Config, first_ping_delay).

cfg_ping_period(Config) -> aesim_config:get(Config, ping_period).

cfg_pong_delay(Config) -> aesim_config:get(Config, pong_delay).

cfg_gossiped_neighbours(Config) -> aesim_config:get(Config, gossiped_neighbours).