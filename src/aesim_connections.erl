-module(aesim_connections).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% API functions
-export([parse_options/2]).
-export([new/2]).
-export([connect/4]).
-export([disconnect/4]).
-export([disconnect_peer/4]).
-export([report/4]).

%% API functions for callback modules
-export([count/2]).
-export([status/2]).
-export([type/2]).
-export([peer/2]).
-export([peer_connections/2]).
-export([has_connection/2]).

%% Event handling functions; only used by aesim_node
-export([route_event/6]).

%=== MACROS ====================================================================

-define(DEFAULT_CONN_MOD, aesim_connection_default).

%=== TYPES =====================================================================

-type connection() :: #{
  ref := conn_ref(),
  peer := id(),
  type := conn_type(),
  status := conn_status(),
  sub := term()
}.

-type state() :: #{
  connections := #{conn_ref() => connection()},
  peer_index := #{id() => #{conn_ref() => true}},
  tag_indexes := #{atom() => #{id() => true}}
}.

-export_type([state/0]).

%=== API FUNCTIONS =============================================================

-spec parse_options(map(), map()) -> map().
parse_options(Config, Opts) ->
  ConnMod = maps:get(conn_mod, Opts, ?DEFAULT_CONN_MOD),
  ConnMod:parse_options(Config#{conn_mod => ConnMod}, Opts).

-spec new(context(), sim()) -> {state(), sim()}.
new(_Context, Sim) ->
  State = #{
    connections => #{},
    peer_index => #{},
    tag_indexes => #{
      inbound => #{},
      outbound => #{},
      connecting => #{},
      connected => #{}
    }
  },
  {State, Sim}.

-spec count(state(), conn_filter() | [conn_filter()]) -> pos_integer().
count(State, Filters) ->
  maps:size(index_tags_get(State, Filters)).

-spec status(state(), conn_ref()) -> conn_status() | undefined.
status(State, ConnRef) ->
  #{connections := Conns} = State,
  case maps:find(ConnRef, Conns) of
    {ok, #{status := Status}} -> Status;
    error -> undefined
  end.

-spec type(state(), conn_ref()) -> conn_type() | undefined.
type(State, ConnRef) ->
  #{connections := Conns} = State,
  case maps:find(ConnRef, Conns) of
    {ok, #{type := Type}} -> Type;
    error -> undefined
  end.

-spec peer(state(), conn_ref()) -> id() | undefined.
peer(State, ConnRef) ->
  #{connections := Conns} = State,
  case maps:find(ConnRef, Conns) of
    {ok, #{peer := PeerId}} -> PeerId;
    error -> undefined
  end.

-spec peer_connections(state(), id()) -> [conn_ref()].
peer_connections(State, PeerId) ->
  maps:keys(index_peers_get(State, PeerId)).

-spec has_connection(state(), id()) -> boolean().
has_connection(State, PeerId) ->
  maps:is_key(PeerId, index_peers_get(State, PeerId)).

-spec connect(state(), id(), context(), sim()) -> {state(), sim()}.
connect(State, PeerId, Context, Sim) ->
  #{node_id := NodeId} = Context,
  ConnRef = make_ref(),
  {Conn, Sim2} = conn_new(ConnRef, PeerId, outbound, connecting, Context, Sim),
  {Conn2, Delay, Opts, Sim3} = conn_connect(Conn, Context, Sim2),
  {_, Sim4} = post_initiated(Delay, NodeId, PeerId, ConnRef, Opts, Sim3),
  {add_connection(State, Conn2), Sim4}.

-spec disconnect(state(), conn_ref(), context(), sim()) -> {state(), sim()}.
disconnect(State, ConnRef, Context, Sim) ->
  #{node_id := NodeId} = Context,
  case get_connection(State, ConnRef) of
    error -> {State, Sim};
    {ok, Conn} ->
      Sim2 = disconnect_effects(NodeId, Conn, Context, Sim),
      {del_connection(State, ConnRef), Sim2}
  end.

-spec disconnect_peer(state(), id(), context(), sim()) -> {state(), sim()}.
disconnect_peer(State, PeerId, Context, Sim) ->
  #{node_id := NodeId} = Context,
  case get_peer_connections(State, PeerId) of
    [] -> {State, Sim};
    Conns ->
      Sim2 = lists:foldl(fun(C, S) ->
        disconnect_effects(NodeId, C, Context, S)
      end, Sim, Conns),
      {del_peer_connections(State, PeerId), Sim2}
  end.

-spec report(state(), report_type(), context(), sim()) -> map().
report(State, _Type, _Context, _Sim) ->
  #{peer_index := PeerIndex} = State,
  #{outbound_count => count(State, [outbound]),
    inbound_count => count(State, [inbound]),
    peer_count => maps:size(PeerIndex)}.

%--- PUBLIC EVENT FUNCTIONS ----------------------------------------------------

-spec route_event(state(), event_addr(), event_name(), term(), context(), sim()) -> {state(), sim()}.
route_event(State, [], initiated, {PeerId, ConnRef, Opts}, Context, Sim) ->
  on_initiated(State, PeerId, ConnRef, Opts, Context, Sim);
route_event(State, [], accepted, ConnRef, Context, Sim) ->
  on_accepted(State, ConnRef, Context, Sim);
route_event(State, [], rejected, ConnRef, Context, Sim) ->
  on_rejected(State, ConnRef, Context, Sim);
route_event(State, [], closed, ConnRef, Context, Sim) ->
  on_closed(State, ConnRef, Context, Sim);
route_event(State, [ConnRef], Name, Params, Context, Sim) ->
  handle_conn_event(State, ConnRef, Name, Params, Context, Sim);
route_event(State, Addr, Name, Params, Context, Sim) ->
  #{node_id := NodeId} = Context,
  lager:warning("Unexpected node ~p connection event ~p ~p: ~p",
                [NodeId, Name, Addr, Params]),
  {State, Sim}.

%=== INTERNAL FUNCTIONS ========================================================

get_connection(State, ConnRef) ->
  #{connections := Conns} = State,
  maps:find(ConnRef, Conns).

get_peer_connections(State, PeerId) ->
  #{connections := Conns} = State,
  ConnRefs = maps:keys(index_peers_get(State, PeerId)),
  maps:values(maps:with(ConnRefs, Conns)).

set_connection(State, Conn) ->
  #{connections := Conns} = State,
  #{ref := ConnRef} = Conn,
  Conns2 = Conns#{ConnRef := Conn},
  State#{connections := Conns2}.

add_connection(State, Conn) ->
  #{connections := Conns} = State,
  #{ref := ConnRef} = Conn,
  ?assertNot(maps:is_key(ConnRef, Conns)),
  Conns2 = Conns#{ConnRef => Conn},
  State2 = State#{connections := Conns2},
  index_connection_added(State2, Conn).

del_connection(State, ConnRef) ->
  #{connections := Conns} = State,
  case maps:take(ConnRef, Conns) of
    error -> State;
    {Conn, Conns2} ->
      State2 = State#{connections := Conns2},
      index_connection_deleted(State2, Conn)
  end.

del_peer_connections(State, PeerId) ->
  ConnRefs = maps:keys(index_peers_get(State, PeerId)),
  lists:foldl(fun(C, S) -> del_connection(S, C) end, State, ConnRefs).

update_status(State, ConnRef, NewStatus) ->
  #{connections := Conns} = State,
  case maps:find(ConnRef, Conns) of
    error -> error;
    {ok, #{status := OldStatus} = Conn} ->
      Conn2 = Conn#{status := NewStatus},
      State2 = State#{connections := Conns#{ConnRef := Conn2}},
      index_tags_update(State2, ConnRef, OldStatus, NewStatus)
  end.

disconnect_effects(NodeId, Conn, Context, Sim) ->
  #{ref := ConnRef, type := ConnType, peer := PeerId} = Conn,
  {Delay, Sim2} = conn_disconnect(Conn, Context, Sim),
  {_, Sim3} = post_closed(Delay, PeerId, ConnRef, Sim2),
  {_, Sim4} = aesim_node:post_conn_closed(0, NodeId, PeerId, ConnRef, ConnType, Sim3),
  Sim4.

%--- PRIVATE EVENT FUNCTIONS ---------------------------------------------------

post(Delay, NodeId, Name, Params, Sim) ->
  aesim_events:post(Delay, [nodes, NodeId, connections], Name, Params, Sim).

post_initiated(Delay, NodeId, PeerId, ConnRef, Opts, Sim) ->
  post(Delay, PeerId, initiated, {NodeId, ConnRef, Opts}, Sim).

post_closed(Delay, PeerId, ConnRef, Sim) ->
  post(Delay, PeerId, closed, ConnRef, Sim).

post_accepted(Delay, PeerId, ConnRef, Sim) ->
  post(Delay, PeerId, accepted, ConnRef, Sim).

post_rejected(Delay, PeerId, ConnRef, Sim) ->
  post(Delay, PeerId, rejected, ConnRef, Sim).

handle_conn_event(State, ConnRef, Name, Params, Context, Sim) ->
  case get_connection(State, ConnRef) of
    error ->
      #{node_id := NodeId} = Context,
      lager:warning("Event ~p for unknown connection of node ~p: ~p",
                    [Name, NodeId, Params]),
      {State, Sim};
    {ok, Conn} ->
      case conn_handle_event(Conn, Name, Params, Context, Sim) of
        {Conn2, Sim2} -> {set_connection(State, Conn2), Sim2};
        ignore -> {State, Sim}
      end
  end.

on_initiated(State, PeerId, ConnRef, Opts, Context, Sim) ->
  {Conn, Sim2} = conn_new(ConnRef, PeerId, inbound, connected, Context, Sim),
  case conn_accept(Conn, Opts, Context, Sim2) of
    {reject, Delay, Sim2} ->
      {_, Sim3} = post_rejected(Delay, PeerId, ConnRef, Sim2),
      {State, Sim3};
    {accept, Conn2, Delay, Sim2} ->
      {_, Sim3} = post_accepted(Delay, PeerId, ConnRef, Sim2),
      {add_connection(State, Conn2), Sim3}
  end.

on_accepted(State, ConnRef, Context, Sim) ->
  #{node_id := NodeId} = Context,
  case get_connection(State, ConnRef) of
    error -> {State, Sim};
    {ok, #{peer := PeerId, type := outbound}} ->
      {_, Sim2} = aesim_node:post_conn_established(0, NodeId, PeerId, ConnRef, outbound, Sim),
      {_, Sim3} = aesim_node:post_conn_established(0, PeerId, NodeId, ConnRef, inbound, Sim2),
      {update_status(State, ConnRef, connected), Sim3}
  end.

on_rejected(State, ConnRef, Context, Sim) ->
  #{node_id := NodeId} = Context,
  case get_connection(State, ConnRef) of
    error -> {State, Sim};
    {ok, #{peer := PeerId, type := outbound}} ->
      {_, Sim2} = aesim_node:post_conn_failed(0, NodeId, PeerId, Sim),
      {del_connection(State, ConnRef), Sim2}
  end.

on_closed(State, ConnRef, Context, Sim) ->
  #{node_id := NodeId} = Context,
  case get_connection(State, ConnRef) of
    error -> {State, Sim};
    {ok, #{peer := PeerId, type := ConnType}} ->
      {_, Sim2} = aesim_node:post_conn_closed(0, NodeId, PeerId, ConnRef, ConnType, Sim),
      {del_connection(State, ConnRef), Sim2}
  end.

%--- INDEX FUNCTIONS -----------------------------------------------------------

% Only the keys of the returned map should be used
index_tags_get(#{connections := Conns}, all) -> Conns;
index_tags_get(State, Filter) when is_atom(Filter) ->
  #{tag_indexes := Indexes} = State,
  #{Filter := Index} = Indexes,
  Index;
index_tags_get(State, Filters) when is_list(Filters) ->
  #{tag_indexes := Indexes} = State,
  lists:foldl(fun(Filter, Acc) ->
    #{Filter := Index} = Indexes,
    maps:merge(Acc, Index)
  end, #{}, Filters).

% Only the keys of the returned map should be used
index_peers_get(State, PeerId) ->
  #{peer_index := Index} = State,
  case maps:find(PeerId, Index) of
    {ok, ConnIndex} -> ConnIndex;
    error -> #{}
  end.

index_connection_added(State, Conn) ->
  #{ref := ConnRef, peer := PeerId, type := Type, status := Status} = Conn,
  State2 = index_peers_add(State, ConnRef, PeerId),
  State3 = index_tags_update(State2, ConnRef, undefined, Type),
  State4 = index_tags_update(State3, ConnRef, undefined, Status),
  State4.

index_connection_deleted(State, Conn) ->
  #{ref := ConnRef, peer := PeerId, type := Type, status := Status} = Conn,
  State2 = index_peers_del(State, ConnRef, PeerId),
  State3 = index_tags_update(State2, ConnRef, Type, undefined),
  State4 = index_tags_update(State3, ConnRef, Status, undefined),
  State4.

index_peers_add(State, ConnRef, PeerId) ->
  #{peer_index := Index} = State,
  ConnIndex = maps:get(PeerId, Index, #{}),
  ConnIndex2 = ConnIndex#{ConnRef => true},
  Index2 = Index#{PeerId => ConnIndex2},
  State#{peer_index := Index2}.

index_peers_del(State, ConnRef, PeerId) ->
  #{peer_index := Index} = State,
  ConnIndex = maps:get(PeerId, Index, #{}),
  ConnIndex2 = maps:remove(ConnRef, ConnIndex),
  Index2 = case maps:size(ConnIndex2) of
    0 -> maps:remove(PeerId, Index);
    _ -> Index#{PeerId => ConnIndex2}
  end,
  State#{peer_index := Index2}.

index_tags_update(State, _ConnRef, SameKey, SameKey) -> State;
index_tags_update(State, ConnRef, Key, undefined) ->
  #{tag_indexes := Indexes} = State,
  #{Key := Index} = Indexes,
  Index2 = maps:remove(ConnRef, Index),
  Indexes2 = Indexes#{Key := Index2},
  State#{tag_indexes := Indexes2};
index_tags_update(State, ConnRef, undefined, Key) ->
  #{tag_indexes := Indexes} = State,
  #{Key := Index} = Indexes,
  Index2 = Index#{ConnRef => true},
  Indexes2 = Indexes#{Key := Index2},
  State#{tag_indexes := Indexes2};
index_tags_update(State, ConnRef, OldKey, NewKey) ->
  #{tag_indexes := Indexes} = State,
  #{OldKey := OldIndex, NewKey := NewIndex} = Indexes,
  OldIndex2 = maps:remove(ConnRef, OldIndex),
  NewIndex2 = NewIndex#{ConnRef => true},
  Indexes2 = Indexes#{OldKey := OldIndex2, NewKey := NewIndex2},
  State#{tag_indexes := Indexes2}.

%--- CONTEXT FUNCTIONS ---------------------------------------------------------

conn_context(Context, Conn) ->
  #{node_id := NodeId} = Context,
  #{ref := ConnRef, peer := PeerId} = Conn,
  Self = [nodes, NodeId, connections, ConnRef],
  Context#{peer_id => PeerId, conn_ref => ConnRef, self => Self}.

%--- CONNECTIONS CALLBACK FUNCTIONS --------------------------------------------

conn_new(ConnRef, PeerId, Type, Status, Context, Sim) ->
  Conn = #{
    ref => ConnRef,
    peer => PeerId,
    type => Type,
    status => Status
  },
  ConnContext = conn_context(Context, Conn),
  ConnMod = cfg_conn_mod(Sim),
  {Sub, Sim2} = ConnMod:conn_new(ConnContext, Sim),
  {Conn#{sub => Sub}, Sim2}.

conn_connect(Conn, Context, Sim) ->
  ConnContext = conn_context(Context, Conn),
  #{sub := Sub} = Conn,
  ConnMod = cfg_conn_mod(Sim),
  {Sub2, Delay, Opts, Sim2} = ConnMod:conn_connect(Sub, ConnContext, Sim),
  {Conn#{sub := Sub2}, Delay, Opts, Sim2}.

conn_accept(Conn, Opts, Context, Sim) ->
  ConnContext = conn_context(Context, Conn),
  #{sub := Sub} = Conn,
  ConnMod = cfg_conn_mod(Sim),
  case ConnMod:conn_accept(Sub, Opts, ConnContext, Sim) of
    {reject, Delay, Sim2} -> {reject, Delay, Sim2};
    {accept, Sub2, Delay, Sim2} ->
      {accept, Conn#{sub := Sub2}, Delay, Sim2}
  end.

conn_disconnect(Conn, Context, Sim) ->
  ConnContext = conn_context(Context, Conn),
  #{sub := Sub} = Conn,
  ConnMod = cfg_conn_mod(Sim),
  ConnMod:conn_disconnect(Sub, ConnContext, Sim).

conn_handle_event(Conn, Name, Params, Context, Sim) ->
  ConnContext = conn_context(Context, Conn),
  #{sub := Sub} = Conn,
  ConnMod = cfg_conn_mod(Sim),
  case ConnMod:conn_handle_event(Sub, Name, Params, ConnContext, Sim) of
    {Sub2, Sim2} -> {Conn#{sub := Sub2}, Sim2};
    ignore -> ignore
  end.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_conn_mod(Config) -> aesim_config:get(Config, conn_mod).
