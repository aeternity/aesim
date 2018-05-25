-module(aesim_connections).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% API functions
-export([report/4]).

%% API functions for callback modules
-export([count/2]).
-export([peers/2]).
-export([status/2]).
-export([type/2]).
-export([peer/2]).
-export([peer_connections/2]).
-export([has_connection/2]).

%% Internal API functions only used by aesim_node
-export([parse_options/2]).
-export([new/2]).
-export([connect/4]).
-export([disconnect/4]).
-export([disconnect_peer/4]).
-export([prepare_accept/6]).
-export([commit_accept/4]).
-export([commit_reject/4]).

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
  peer_index := #{id() => sets:set(conn_ref())},
  tag_indexes := #{atom() => sets:set(conn_ref())}
}.

-export_type([state/0]).

%=== API FUNCTIONS =============================================================

-spec report(state(), report_type(), context(), sim()) -> map().
report(State, _Type, _Context, _Sim) ->
  #{peer_index := PeerIndex} = State,
  #{outbound_count => count(State, [outbound]),
    inbound_count => count(State, [inbound]),
    peer_count => maps:size(PeerIndex)}.

%--- INTERNAL API FUNCTIONS ----------------------------------------------------

-spec parse_options(map(), sim()) -> sim().
parse_options(Opts, Sim) ->
  aesim_config:parse(Sim, Opts, [
    {conn_mod, atom, ?DEFAULT_CONN_MOD}
  ], [
    {conn_mod, parse_options}
  ]).

-spec new(context(), sim()) -> {state(), sim()}.
new(_Context, Sim) ->
  State = #{
    connections => #{},
    peer_index => #{},
    tag_indexes => #{
      inbound => sets:new(),
      outbound => sets:new(),
      connecting => sets:new(),
      connected => sets:new()
    }
  },
  {State, Sim}.

-spec count(state(), all | conn_filter() | [conn_filter()]) -> pos_integer().
count(State, Filters) ->
  index_size(index_tags_get(State, Filters)).

-spec peers(state(), all | conn_filter() | [conn_filter()]) -> [id()].
peers(State, Filters) ->
  #{connections := Conns} = State,
  [maps:get(peer, maps:get(R, Conns))
   || R <- index_keys(index_tags_get(State, Filters))].

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
  index_keys(index_peers_get(State, PeerId)).

-spec has_connection(state(), id()) -> boolean().
has_connection(State, PeerId) ->
  index_has_key(PeerId, index_peers_get(State, PeerId)).

-spec connect(state(), id(), context(), sim()) -> {state(), sim()}.
connect(State, PeerId, Context, Sim) ->
  #{node_id := NodeId} = Context,
  Sim2 = metrics_inc([connections, connect], Context, Sim),
  ConnRef = make_ref(),
  {Conn, Sim3} = conn_new(ConnRef, PeerId, outbound, connecting, Context, Sim2),
  {Conn2, Delay, Opts, Sim4} = conn_connect(Conn, Context, Sim3),
  {_, Sim5} = aesim_node:post_conn_initiated(Delay, PeerId, NodeId, ConnRef, Opts, Sim4),
  {add_connection(State, Conn2), Sim5}.

-spec disconnect(state(), conn_ref(), context(), sim()) -> {state(), sim()}.
disconnect(State, ConnRef, Context, Sim) ->
  #{node_id := NodeId} = Context,
  case get_connection(State, ConnRef) of
    error -> {State, Sim};
    {ok, #{status := connected, type := ConnType, peer := PeerId} = Conn} ->
      Sim2 = metrics_inc([connections, disconnect], Context, Sim),
      {Delay, Sim3} = conn_disconnect(Conn, Context, Sim2),
      {_, Sim4} = post_closed(Delay, PeerId, ConnRef, Sim3),
      Sim5 = aesim_node:async_conn_terminated(NodeId, PeerId, ConnRef, ConnType, Sim4),
      {del_connection(State, ConnRef), Sim5};
    {ok, #{status := connecting, peer := PeerId}} ->
      Sim2 = async_aborted(PeerId, ConnRef, Sim),
      {del_connection(State, ConnRef), Sim2}
  end.

-spec disconnect_peer(state(), id(), context(), sim()) -> {state(), sim()}.
disconnect_peer(State0, PeerId, Context, Sim0) ->
  case get_peer_conn_refs(State0, PeerId) of
    [] -> {State0, Sim0};
    ConnRefs ->
      lists:foldl(fun(ConnRef, {State, Sim}) ->
        disconnect(State, ConnRef, Context, Sim)
      end, {State0, Sim0}, ConnRefs)
  end.

-spec prepare_accept(state(), id(), conn_ref(), term(), context(), sim())
  -> {accept, state(), term(), sim()} | {reject, state(), sim()}.
prepare_accept(State, PeerId, ConnRef, Opts, Context, Sim) ->
  {Conn, Sim2} = conn_new(ConnRef, PeerId, inbound, connecting, Context, Sim),
  case conn_accept(Conn, Opts, Context, Sim2) of
    {reject, Delay, Sim2} ->
      {_, Sim3} = post_rejected(Delay, PeerId, ConnRef, Sim2),
      {reject, State, Sim3};
    {accept, Conn2, Delay, Sim2} ->
      {accept, State, {Conn2, Delay}, Sim2}
  end.

-spec commit_accept(state(), term(), context(), sim()) -> {state(), sim()}.
commit_accept(State, {Conn, Delay}, _Context, Sim) ->
  #{peer := PeerId, ref := ConnRef} = Conn,
  {_, Sim2} = post_accepted(Delay, PeerId, ConnRef, Sim),
  {add_connection(State, Conn), Sim2}.

-spec commit_reject(state(), term(), context(), sim()) -> {state(), sim()}.
commit_reject(State, {Conn, _Delay}, Context, Sim) ->
  #{peer := PeerId, ref := ConnRef} = Conn,
  {Delay, Sim2} = conn_reject(Conn, Context, Sim),
  {_, Sim3} = post_rejected(Delay, PeerId, ConnRef, Sim2),
  {State, Sim3}.

%--- PUBLIC EVENT FUNCTIONS ----------------------------------------------------

-spec route_event(state(), event_addr(), event_name(), term(), context(), sim()) -> {state(), sim()}.
route_event(State, [], accepted, ConnRef, Context, Sim) ->
  on_accepted(State, ConnRef, Context, Sim);
route_event(State, [], rejected, ConnRef, Context, Sim) ->
  on_rejected(State, ConnRef, Context, Sim);
route_event(State, [], closed, ConnRef, Context, Sim) ->
  on_closed(State, ConnRef, Context, Sim);
route_event(State, [], confirmed, ConnRef, Context, Sim) ->
  on_confirmed(State, ConnRef, Context, Sim);
route_event(State, [], aborted, ConnRef, Context, Sim) ->
  on_aborted(State, ConnRef, Context, Sim);
route_event(State, [ConnRef], Name, Params, Context, Sim) ->
  handle_conn_event(State, ConnRef, Name, Params, Context, Sim);
route_event(State, Addr, Name, Params, Context, Sim) ->
  #{node_id := NodeId} = Context,
  lager:warning("Unexpected node ~p connection event ~p ~p: ~p",
                [NodeId, Name, Addr, Params]),
  {State, Sim}.

%=== INTERNAL FUNCTIONS ========================================================

metrics_inc(Name, Context, Sim) ->
  #{node_id := NodeId} = Context,
  aesim_metrics:inc(NodeId, Name, 1, Sim).

get_connection(State, ConnRef) ->
  #{connections := Conns} = State,
  maps:find(ConnRef, Conns).

get_peer_conn_refs(State, PeerId) ->
  index_keys(index_peers_get(State, PeerId)).

% Connection status and type shouldn't be changed; this doesn't update the index
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

update_status(State, ConnRef, NewStatus) ->
  #{connections := Conns} = State,
  case maps:find(ConnRef, Conns) of
    error -> error;
    {ok, #{status := OldStatus} = Conn} ->
      Conn2 = Conn#{status := NewStatus},
      State2 = State#{connections := Conns#{ConnRef := Conn2}},
      index_tags_update(State2, ConnRef, OldStatus, NewStatus)
  end.

%--- PRIVATE EVENT FUNCTIONS ---------------------------------------------------

post(Delay, NodeId, Name, Params, Sim) ->
  aesim_events:post(Delay, [nodes, NodeId, connections], Name, Params, Sim).

post_closed(Delay, NodeId, ConnRef, Sim) ->
  post(Delay, NodeId, closed, ConnRef, Sim).

post_accepted(Delay, NodeId, ConnRef, Sim) ->
  post(Delay, NodeId, accepted, ConnRef, Sim).

post_rejected(Delay, NodeId, ConnRef, Sim) ->
  post(Delay, NodeId, rejected, ConnRef, Sim).

async_confirmed(NodeId, ConnRef, Sim) ->
  {_, Sim2} = post(0, NodeId, confirmed, ConnRef, Sim),
  Sim2.

async_aborted(NodeId, ConnRef, Sim) ->
  {_, Sim2} = post(0, NodeId, aborted, ConnRef, Sim),
  Sim2.

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

on_accepted(State, ConnRef, Context, Sim) ->
  #{node_id := NodeId} = Context,
  case get_connection(State, ConnRef) of
    error -> {State, Sim};
    {ok, #{peer := PeerId, type := outbound}} ->
      Sim2 = async_confirmed(PeerId, ConnRef, Sim),
      Sim3 = aesim_node:async_conn_established(NodeId, PeerId, ConnRef, outbound, Sim2),
      {update_status(State, ConnRef, connected), Sim3}
  end.

on_rejected(State, ConnRef, Context, Sim) ->
  #{node_id := NodeId} = Context,
  case get_connection(State, ConnRef) of
    error -> {State, Sim};
    {ok, #{peer := PeerId, type := outbound}} ->
      Sim2 = aesim_node:async_conn_failed(NodeId, PeerId, Sim),
      {del_connection(State, ConnRef), Sim2}
  end.

on_closed(State, ConnRef, Context, Sim) ->
  #{node_id := NodeId} = Context,
  case get_connection(State, ConnRef) of
    error -> {State, Sim};
    {ok, #{peer := PeerId, type := ConnType}} ->
      Sim2 = aesim_node:async_conn_terminated(NodeId, PeerId, ConnRef, ConnType, Sim),
      {del_connection(State, ConnRef), Sim2}
  end.

%% The inbound connection is confirmed
on_confirmed(State, ConnRef, Context, Sim) ->
  #{node_id := NodeId} = Context,
  case get_connection(State, ConnRef) of
    error -> {State, Sim};
    {ok, #{peer := PeerId, type := inbound}} ->
      Sim2 = aesim_node:async_conn_established(NodeId, PeerId, ConnRef, inbound, Sim),
      {update_status(State, ConnRef, connected), Sim2}
  end.

%% The connection got closed before it got established
on_aborted(State, ConnRef, _Context, Sim) ->
  {del_connection(State, ConnRef), Sim}.

%--- INDEX FUNCTIONS -----------------------------------------------------------

%% Dialyzer don't like we call `is_map` on an opaque type
-dialyzer({nowarn_function, index_keys/1}).
-spec index_keys(sets:set() | map()) -> [term()].
index_keys(Map) when is_map(Map) -> maps:keys(Map);
index_keys(Set) -> sets:to_list(Set).

%% Dialyzer don't like we call `is_map` on an opaque type
-dialyzer({nowarn_function, index_size/1}).
-spec index_size(sets:set() | map()) -> non_neg_integer().
index_size(Map) when is_map(Map) -> maps:size(Map);
index_size(Set) -> sets:size(Set).

%% Dialyzer don't like we call `is_map` on an opaque type
-dialyzer({nowarn_function, index_has_key/2}).
-spec index_has_key(term(), sets:set() | map()) -> boolean().
index_has_key(Key, Map) when is_map(Map) -> maps:is_key(Key, Map);
index_has_key(Key, Set) -> sets:is_element(Key, Set).

-spec index_tags_get(state(), all | conn_filter() | [conn_filter()]) -> sets:set() | map().
index_tags_get(#{connections := Conns}, all) -> Conns;
index_tags_get(State, [Filter]) ->
  index_tags_get(State, Filter);
index_tags_get(State, Filter) when is_atom(Filter) ->
  #{tag_indexes := Indexes} = State,
  #{Filter := Index} = Indexes,
  Index;
index_tags_get(State, [Filter | Filters]) ->
  #{tag_indexes := Indexes} = State,
  #{Filter := Index} = Indexes,
  lists:foldl(fun(F, Acc) ->
    #{F := I} = Indexes,
    sets:intersection(Acc, I)
  end, Index, Filters).

-spec index_peers_get(state(), id()) -> sets:set().
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
  ConnIndex = maps:get(PeerId, Index, sets:new()),
  ConnIndex2 = sets:add_element(ConnRef, ConnIndex),
  Index2 = Index#{PeerId => ConnIndex2},
  State#{peer_index := Index2}.

index_peers_del(State, ConnRef, PeerId) ->
  #{peer_index := Index} = State,
  ConnIndex = maps:get(PeerId, Index, sets:new()),
  ConnIndex2 = sets:del_element(ConnRef, ConnIndex),
  Index2 = case sets:size(ConnIndex2) of
    0 -> maps:remove(PeerId, Index);
    _ -> Index#{PeerId => ConnIndex2}
  end,
  State#{peer_index := Index2}.

index_tags_update(State, _ConnRef, SameKey, SameKey) -> State;
index_tags_update(State, ConnRef, Key, undefined) ->
  #{tag_indexes := Indexes} = State,
  #{Key := Index} = Indexes,
  Index2 = sets:del_element(ConnRef, Index),
  Indexes2 = Indexes#{Key := Index2},
  State#{tag_indexes := Indexes2};
index_tags_update(State, ConnRef, undefined, Key) ->
  #{tag_indexes := Indexes} = State,
  #{Key := Index} = Indexes,
  Index2 = sets:add_element(ConnRef, Index),
  Indexes2 = Indexes#{Key := Index2},
  State#{tag_indexes := Indexes2};
index_tags_update(State, ConnRef, OldKey, NewKey) ->
  #{tag_indexes := Indexes} = State,
  #{OldKey := OldIndex, NewKey := NewIndex} = Indexes,
  OldIndex2 = sets:del_element(ConnRef, OldIndex),
  NewIndex2 = sets:add_element(ConnRef, NewIndex),
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

conn_reject(Conn, Context, Sim) ->
  ConnContext = conn_context(Context, Conn),
  #{sub := Sub} = Conn,
  ConnMod = cfg_conn_mod(Sim),
  ConnMod:conn_reject(Sub, ConnContext, Sim).

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

cfg_conn_mod(Sim) -> aesim_config:get(Sim, conn_mod).
