-module(aesim_pool_stochastic).

-behaviour(aesim_pool).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% Behaviour aesim_pool callback functions
-export([parse_options/2]).
-export([pool_new/2]).
-export([pool_init/4]).
-export([pool_count/2]).
-export([pool_select/5]).
-export([pool_gossip/5]).
-export([pool_handle_event/5]).
-export([report/4]).

%=== MACROS ====================================================================

-define(BACKOFF_TIMES, [5, 15, 30, 60, 120, 300, 600]).
-define(MAX_RETRIES, 7).

%% Number of buckets in the verified pool
-define(DEFAULT_VER_BUCKET_COUNT,      256).
%% Number of peers in each verified pool buckets
-define(DEFAULT_VER_BUCKET_SIZE,        32).
%% Shard size of verified bucket selected based on peer address
-define(DEFAULT_VER_SHARD_PEER_LOW,      8).
%% Number of buckets in the unverified pool
-define(DEFAULT_UNV_BUCKET_COUNT,     1024).
%% Number of peers in each unverified buckets
-define(DEFAULT_UNV_BUCKET_SIZE,        64).
%% Shard size of unverified bucket selected based on source address group
-define(DEFAULT_UNV_SHARD_PEER_HIGH,    64).
%% Shard size of unverified bucket selected based on peer address
-define(DEFAULT_UNV_SHARD_PEER_LOW,      4).
%% Maximum number of unverified peer references in the unverified pool
-define(DEFAULT_MAX_UNV_PEER_REFS,       8).
%% Eviction skew toward older peers; it is used in the formula `Max * pow(random(), SKEW)`
-define(DEFAULT_EVICTION_SKEW,         1.2).
%% Probability of selecting a peer from the verified pool
-define(DEFAULT_VERIFIED_PROB,         0.5).

%=== TYPES =====================================================================

-type pool_peer() :: #{
  vidx := non_neg_integer() | undefined,
  uidxs := [non_neg_integer()]
}.

-type state() :: #{
  secret := binary(),
  peers := #{id() => pool_peer()},
  verified_count := non_neg_integer(),
  verified := array:array([]),
  unverified_count := non_neg_integer(),
  unverified := array:array([])
}.

%=== BEHAVIOUR aesim_pool CALLBACK FUNCTIONS ===================================

parse_options(Opts, Sim) ->
  aesim_config:parse(Sim, Opts, [
    {ver_bucket_count, integer, ?DEFAULT_VER_BUCKET_COUNT},
    {ver_bucket_size, integer, ?DEFAULT_VER_BUCKET_SIZE},
    {ver_low_shard, integer, ?DEFAULT_VER_SHARD_PEER_LOW},
    {unv_bucket_count, integer, ?DEFAULT_UNV_BUCKET_COUNT},
    {unv_bucket_size, integer, ?DEFAULT_UNV_BUCKET_SIZE},
    {unv_high_shard, integer, ?DEFAULT_UNV_SHARD_PEER_HIGH},
    {unv_low_shard, integer, ?DEFAULT_UNV_SHARD_PEER_LOW},
    {unv_max_refs, integer, ?DEFAULT_MAX_UNV_PEER_REFS},
    {eviction_skew, number, ?DEFAULT_EVICTION_SKEW},
    {verified_prob, number, ?DEFAULT_VERIFIED_PROB}
  ]).

-spec pool_new(context(), sim()) -> {state(), sim()}.
pool_new(_Context, Sim) ->
  State = #{
    secret => gen_secret(),
    peers => #{},
    verified_count => 0,
    verified => array:new(cfg_ver_bucket_count(Sim), [{default, []}]),
    unverified_count => 0,
    unverified => array:new(cfg_unv_bucket_count(Sim), [{default, []}])
  },
  {State, Sim}.

pool_init(State0, Trusted, Context, Sim0) ->
  % Add trusted peers directly to the verified pool
  lists:foldl(fun({PeerId, _}, {State, Sim}) ->
    {State2, Sim2} = add_peer(State, PeerId, Context, Sim),
    verified_add(State2, PeerId, Context, Sim2)
  end, {State0, Sim0}, Trusted).

pool_count(State, all) ->
  #{verified_count := VCount, unverified_count := UCount} = State,
  VCount + UCount;
pool_count(#{verified_count := VCount}, verified) -> VCount;
pool_count(#{unverified_count := UCount}, unverified) -> UCount.

pool_select(State, ExIds, ExGroups, Context, Sim) ->
  #{peers := PooledPeers} = State,
  PeerIds = maps:keys(PooledPeers),
  case aesim_pool:filter_peers(PeerIds, ExIds, ExGroups, ?MAX_RETRIES,
                               fun retry_backoff/2, Context, Sim) of
    {undefined, [], Sim2} ->
      {unavailable, Sim2};
    {NextTime, [], Sim2} ->
      {retry, NextTime, Sim2};
    {_NextTime, AvailableIds, Sim2} ->
      {PeerId, Sim3} = select_peer(State, AvailableIds, Context, Sim2),
      ?assertNotEqual(undefined, PeerId),
      {selected, PeerId, Sim3}
  end.

pool_gossip(State, all, Exclude, _Context, Sim) ->
  #{peers := Peers} = State,
  {maps:keys(maps:without(Exclude, Peers)), Sim};
pool_gossip(State, Count, Exclude, _Context, Sim) ->
  #{peers := Peers} = State,
  {aesim_utils:rand_pick(Count, maps:keys(Peers), Exclude), Sim}.

pool_handle_event(State, conn_established, {PeerId, ConnRef, ConnType}, Context, Sim) ->
  on_connection_established(State, PeerId, ConnRef, ConnType, Context, Sim);
pool_handle_event(State, peer_identified, PeerId, Context, Sim) ->
  on_peer_identified(State, PeerId, Context, Sim);
pool_handle_event(State, peer_expired, PeerId, Context, Sim) ->
  on_peer_expired(State, PeerId, Context, Sim);
pool_handle_event(_State, _Name, _Params, _Context, _Sim) -> ignore.

report(State, _Type, _Context, _Sim) ->
  #{peers := PooledPeers,
    verified_count := VCount,
    unverified_count := UCount
  } = State,
  #{known_count => maps:size(PooledPeers),
    verified_count => VCount,
    unverified_count => UCount}.

%=== INTERNAL FUNCTIONS ========================================================

gen_secret() ->
  crypto:strong_rand_bytes(128).

retry_backoff(0, _) -> undefined;
retry_backoff(RetryCount, RetryTime) ->
  BackoffIndex = min(RetryCount, length(?BACKOFF_TIMES)),
  RetryTime + lists:nth(BackoffIndex, ?BACKOFF_TIMES) * 1000.

hash_modulo(Bin, Modulo) ->
  <<I:160/little-unsigned-integer>> = crypto:hash(sha, Bin),
  I rem Modulo.

should_add_unverified_ref(RefCount, _Sim) ->
  aesim_utils:rand(floor(math:pow(2, RefCount))) =:= 0.

add_peer(State, PeerId, Context, Sim) ->
  #{node_id := NodeId} = Context,
  #{peers := PooledPeers} = State,
  case maps:find(PeerId, PooledPeers) of
    {ok, _} -> {State, Sim};
    error ->
      % First time we know about this peer
      PooledPeer = #{vidx => undefined, uidxs => []},
      PooledPeers2 = PooledPeers#{PeerId => PooledPeer},
      State2 = State#{peers := PooledPeers2},
      Sim2 = aesim_metrics:inc(NodeId, [pool, known], 1, Sim),
      {State2, Sim2}
  end.

select_peer(State, AvailableIds, Context, Sim) ->
  % The pool that will be tried first is selected trowing the dice.
  Prob = cfg_verified_prob(Sim),
  IntProb = floor(Prob * 1000),
  ?assert((IntProb >= 0) and (IntProb =< 1000)),
  case aesim_utils:rand(1001) < IntProb of
    true ->
      {PeerId, Sim2} = maybe_select_verified(State, AvailableIds, undefined, Context, Sim),
      maybe_select_unverified(State, AvailableIds, PeerId, Context, Sim2);
    false ->
      {PeerId, Sim2} = maybe_select_unverified(State, AvailableIds, undefined, Context, Sim),
      maybe_select_verified(State, AvailableIds, PeerId, Context, Sim2)
  end.

maybe_select_verified(State, AvailableIds, undefined, _Context, Sim) ->
  case filter_verified(State, AvailableIds) of
    [] -> {undefined, Sim};
    VerifiedIds ->
      {aesim_utils:rand_pick(VerifiedIds), Sim}
  end;
maybe_select_verified(_State, _AvailableIds, PeerId, _Context, Sim) ->
  {PeerId, Sim}.

maybe_select_unverified(State, AvailableIds, undefined, _Context, Sim) ->
  case filter_unverified(State, AvailableIds) of
    [] -> {undefined, Sim};
    UnverifiedIds ->
      {aesim_utils:rand_pick(UnverifiedIds), Sim}
  end;
maybe_select_unverified(_State, _AvailableIds, PeerId, _Context, Sim) ->
  {PeerId, Sim}.

filter_verified(State, Ids) ->
  lists:filter(fun(I) -> is_verified(State, I) end, Ids).

filter_unverified(State, Ids) ->
  lists:filter(fun(I) -> is_unverified(State, I) end, Ids).

%--- EVENT HANDLING FUNCTIONS --------------------------------------------------

on_peer_identified(State, PeerId, Context, Sim) ->
  % When a peer is identified, we add it to the verified pool if we are
  % connected to it, otherwise we add it to the unverified pool.
  #{conns := Conns} = Context,
  {State2, Sim2} = add_peer(State, PeerId, Context, Sim),
  case aesim_connections:has_connection(Conns, PeerId) of
    true -> verified_add(State2, PeerId, Context, Sim2);
    false -> unverified_add(State2, PeerId, Context, Sim2)
  end.

on_connection_established(State, PeerId, _ConnRef, _ConnType, Context, Sim) ->
  % When connected to a peer, we check if the peer is identified (has an address),
  % If it is we add it to the verified pool, otherwise we don't do anything and
  % wait to get an `on_peer_identified` event.
  #{peers := Peers} = Context,
  #{PeerId := Peer} = Peers,
  #{addr := PeerAddr} = Peer,
  case PeerAddr of
    undefined -> {State, Sim};
    PeerAddr ->
      {State2, Sim2} = add_peer(State, PeerId, Context, Sim),
      verified_add(State2, PeerId, Context, Sim2)
  end.

on_peer_expired(State, PeerId, Context, Sim) ->
  % When a peer has expired we downgrade it or remove it.
  {State2, Sim2} = add_peer(State, PeerId, Context, Sim),
  case is_verified(State, PeerId) of
    true -> verified_downgrade(State2, PeerId, Context, Sim2);
    false -> unverified_del(State2, PeerId, Context, Sim2)
  end.

%--- VERIFIED POOL FUNCTIONS ---------------------------------------------------

is_verified(State, PeerId) ->
  #{peers := PooledPeers} = State,
  case maps:find(PeerId, PooledPeers) of
    error -> false;
    {ok, #{vidx := CurrIdx}} ->
      CurrIdx =/= undefined
  end.

verified_bucket_index(State, PeerAddress, Sim) ->
  #{secret := Secret} = State,
  VBCount = cfg_ver_bucket_count(Sim),
  VSPLow = cfg_ver_low_shard(Sim),
  {{PA, PB, PC, PD}, _} = PeerAddress,
  A = hash_modulo(<<Secret/binary, PC:8, PD:8>>, VSPLow),
  hash_modulo(<<Secret/binary, PA:8, PB:8, A:8>>, VBCount).

verified_add(State, PeerId, Context, Sim) ->
  #{node_id := NodeId, peers := Peers} = Context,
  #{PeerId := Peer} = Peers,
  #{addr := PeerAddr} = Peer,
  ?assertNotEqual(undefined, PeerAddr),
  case is_verified(State, PeerId) of
    true -> {State, Sim};
    false ->
      % Not yet in the verified pool
      {State2, Sim2} = unverified_del(State, PeerId, Context, Sim),
      Idx = verified_bucket_index(State, PeerAddr, Sim),
      {State3, Sim3} = verified_make_space(State2, Idx, Context, Sim2),
      #{verified := Buckets,
        verified_count := Count,
        peers := PooledPeers
      } = State2,
      #{PeerId := PooledPeer} = PooledPeers,
      ?assertMatch(#{vidx := undefined}, PooledPeer),
      Buckets2 = bucket_add(Buckets, Idx, PeerId),
      Sim4 = aesim_metrics:inc(NodeId, [pool, verified], 1, Sim3),
      PooledPeer2 = PooledPeer#{vidx := Idx},
      PooledPeers2 = PooledPeers#{PeerId := PooledPeer2},
      State4 = State3#{
        peers := PooledPeers2,
        verified := Buckets2,
        verified_count := Count + 1
      },
      {State4, Sim4}
  end.

verified_downgrade(State, PeerId, Context, Sim) ->
  #{node_id := NodeId} = Context,
  #{peers := PooledPeers, verified_count := Count} = State,
  ?assert(Count >= 1),
  #{PeerId := PooledPeer} = PooledPeers,
  ?assertNotEqual(undefined, maps:get(vidx, PooledPeer)),
  Sim2 = aesim_metrics:inc(NodeId, [pool, verified], -1, Sim),
  Sim3 = aesim_metrics:inc(NodeId, [pool, downgraded], 1, Sim2),
  PooledPeer2 = PooledPeer#{vidx := undefined},
  PooledPeers2 = PooledPeers#{PeerId := PooledPeer2},
  State2 = State#{peers := PooledPeers2, verified_count := Count - 1},
  unverified_add(State2, PeerId, Context, Sim3).

verified_make_space(State, Idx, Context, Sim) ->
  % When evicting we want to skew the random selection in favor of the peers
  % we connected to the longest time ago, but are not connected right now.
  BucketSize = cfg_ver_bucket_size(Sim),
  Skew = cfg_eviction_skew(Sim),
  #{verified := Buckets} = State,
  #{peers := Peers, conns := Conns} = Context,
  #{time := Now} = Sim,
  SortKeyFun = fun(PeerId) ->
    #{PeerId := Peer} = Peers,
    #{conn_time := ConnTime} = Peer,
    ?assertNotEqual(undefined, ConnTime),
    case aesim_connections:has_connection(Conns, PeerId) of
        true -> Now;
        false -> ConnTime
    end
  end,
  case bucket_make_space(Buckets, Idx, BucketSize - 1, Skew, SortKeyFun) of
    ok -> {State, Sim};
    {Buckets2, EvictedPeerId} ->
      State2 = State#{verified := Buckets2},
      verified_downgrade(State2, EvictedPeerId, Context, Sim)
  end.

%--- UNVERIFIED POOL FUNCTIONS -------------------------------------------------

is_unverified(State, PeerId) ->
  #{peers := PooledPeers} = State,
  case maps:find(PeerId, PooledPeers) of
    error -> false;
    {ok, #{uidxs := []}} -> false;
    {ok, #{uidxs := [_|_]}} -> true
  end.

unverified_bucket_index(State, SourceAddress, PeerAddress, Sim) ->
  #{secret := Secret} = State,
  UBCount = cfg_unv_bucket_count(Sim),
  USPHigh = cfg_unv_high_shard(Sim),
  USPLow = cfg_unv_low_shard(Sim),
  ?assertEqual(0, USPHigh rem USPLow),
  {{SA, SB, _, _}, _} = SourceAddress,
  {{PA, PB, PC, PD}, _} = PeerAddress,
  A = hash_modulo(<<Secret/binary, PA:8, PB:8>>, USPHigh div USPLow),
  B = hash_modulo(<<Secret/binary, PC:8, PD:8>>, USPLow),
  hash_modulo(<<Secret/binary, SA:8, SB:8, A:8, B:8>>, UBCount).

unverified_add(State, PeerId, Context, Sim) ->
  #{node_id := NodeId} = Context,
  #{peers := PooledPeers, unverified_count := Count} = State,
  #{PeerId := PooledPeer} = PooledPeers,
  case PooledPeer of
    #{vidx := CurrIdx} when CurrIdx =/= undefined ->
      % Already in verified pool
      {State, Sim};
    #{uidxs := []} ->
      % First time added a unverified peer
      State2 = State#{unverified_count := Count + 1},
      Sim2 = aesim_metrics:inc(NodeId, [pool, unverified], 1, Sim),
      unverified_add_reference(State2, PeerId, Context, Sim2);
    #{uidxs := Refs} ->
      MaxRefs = cfg_unv_max_refs(Sim),
      RefCount = length(Refs),
      case RefCount >= MaxRefs of
        true -> {State, Sim};
        false ->
          case should_add_unverified_ref(RefCount, Sim) of
            false -> {State, Sim};
            true ->
              unverified_add_reference(State, PeerId, Context, Sim)
          end
      end
  end.

unverified_add_reference(State, PeerId, Context, Sim) ->
  #{peers := Peers} = Context,
  #{PeerId := Peer} = Peers,
  #{addr := PeerAddr, source_addr := SourceAddr} = Peer,
  ?assertNotEqual(undefined, PeerAddr),
  ?assertNotEqual(undefined, SourceAddr),
  Idx = unverified_bucket_index(State, SourceAddr, PeerAddr, Sim),
  #{unverified := Buckets0} = State,
  case bucket_has(Buckets0, Idx, PeerId) of
    true -> {State, Sim};
    false ->
      {State2, Sim2} = unverified_make_space(State, Idx, Context, Sim),
      #{unverified := Buckets, peers := PooledPeers} = State2,
      #{PeerId := PooledPeer} = PooledPeers,
      #{uidxs := CurrRefs} = PooledPeer,
      Buckets2 = bucket_add(Buckets, Idx, PeerId),
      PooledPeer2 = PooledPeer#{uidxs := [Idx | CurrRefs]},
      PooledPeers2 = PooledPeers#{PeerId := PooledPeer2},
      State3 = State2#{peers := PooledPeers2, unverified := Buckets2},
      {State3, Sim2}
  end.

unverified_remove_reference(State, PeerId, Idx, Context, Sim) ->
  #{node_id := NodeId} = Context,
  #{peers := PooledPeers, unverified_count := Count} = State,
  ?assert(Count >= 1),
  #{PeerId := PooledPeer} = PooledPeers,
  ?assertNotEqual([], maps:get(uidxs, PooledPeer)),
  case PooledPeer of
    #{uidxs := [Idx]} ->
      % Last reference is removed
      PooledPeer2 = PooledPeer#{uidxs := []},
      PooledPeers2 = PooledPeers#{PeerId := PooledPeer2},
      State2 = State#{peers := PooledPeers2, unverified_count := Count - 1},
      Sim2 = aesim_metrics:inc(NodeId, [pool, unverified], -1, Sim),
      Sim3 = aesim_metrics:inc(NodeId, [pool, removed], 1, Sim2),
      {State2, Sim3};
    #{uidxs := Refs} ->
      % Peer is still referenced in other buckets
      ?assert(lists:member(Idx, Refs)),
      Refs2 = lists:delete(Idx, Refs),
      ?assertNotMatch([], Refs2),
      PooledPeer2 = PooledPeer#{uidxs := Refs2},
      PooledPeers2 = PooledPeers#{PeerId := PooledPeer2},
      State2 = State#{peers := PooledPeers2},
      {State2, Sim}
  end.

unverified_del(State, PeerId, Context, Sim) ->
  #{node_id := NodeId} = Context,
  #{peers := PooledPeers} = State,
  case maps:find(PeerId, PooledPeers) of
    error -> {State, Sim};
    {ok, #{uidxs := []}} -> {State, Sim};
    {ok, #{uidxs := BucketIdxs} = PooledPeer} ->
      #{unverified := Buckets, unverified_count := Count} = State,
      ?assert(Count >= 1),
      Sim2 = aesim_metrics:inc(NodeId, [pool, unverified], -1, Sim),
      Buckets2 = lists:foldl(fun(I, B) ->
        bucket_del(B, I, PeerId)
      end, Buckets, BucketIdxs),
      PooledPeer2 = PooledPeer#{uidxs := []},
      PooledPeers2 = PooledPeers#{PeerId := PooledPeer2},
      State2 = State#{
        unverified := Buckets2,
        peers := PooledPeers2,
        unverified_count := Count - 1
      },
      {State2, Sim2}
  end.

unverified_make_space(State, Idx, Context, Sim) ->
  % When evicting we want to skew the random selection in favor of the peers
  % that were gossiped to the longest time ago.
  BucketSize = cfg_unv_bucket_size(Sim),
  Skew = cfg_eviction_skew(Sim),
  #{unverified := Buckets} = State,
  #{peers := Peers} = Context,
  SortKeyFun = fun(PeerId) ->
    #{PeerId := Peer} = Peers,
    #{gossip_time := GossipTime} = Peer,
    GossipTime
  end,
  case bucket_make_space(Buckets, Idx, BucketSize - 1, Skew, SortKeyFun) of
    ok -> {State, Sim};
    {Buckets2, EvictedPeerId} ->
      State2 = State#{unverified := Buckets2},
      unverified_remove_reference(State2, EvictedPeerId, Idx, Context, Sim)
  end.

%--- BUCKET HANDLING FUNCTIONS -------------------------------------------------

bucket_del(Buckets, Idx, PeerId) ->
  Bucket = array:get(Idx, Buckets),
  ?assert(lists:member(PeerId, Bucket)),
  Bucket2 = lists:delete(PeerId, Bucket),
  array:set(Idx, Bucket2, Buckets).

bucket_add(Buckets, Idx, PeerId) ->
  Bucket = array:get(Idx, Buckets),
  array:set(Idx, [PeerId | Bucket], Buckets).

bucket_has(Buckets, Idx, PeerId) ->
  Bucket = array:get(Idx, Buckets),
  lists:member(PeerId, Bucket).

bucket_make_space(Buckets, Idx, MaxSize, Skew, SortKeyFun) ->
  Bucket = array:get(Idx, Buckets),
  %TODO: evict peers not gossiped for a long time
  Size = length(Bucket),
  case Size =< MaxSize of
    true -> ok;
    false ->
      % We need to evict a peer from this bucket; we will sort it using
      % the keys given by the specified function and then select one with
      % the given skew toward smaller index (`1.0` -> no skew).
      SortedBucket = lists:keysort(1, [{SortKeyFun(I), I} || I <- Bucket]),
      RandIdx = aesim_utils:skewed_rand(Size, Skew),
      {Head, [{_, Evicted} | Tail]} = lists:split(RandIdx, SortedBucket),
      Bucket2 = [I || {_, I} <- Head ++ Tail],
      Buckets2 = array:set(Idx, Bucket2, Buckets),
      {Buckets2, Evicted}
  end.

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_ver_bucket_count(Sim) -> aesim_config:get(Sim, ver_bucket_count).

cfg_ver_bucket_size(Sim) -> aesim_config:get(Sim, ver_bucket_size).

cfg_ver_low_shard(Sim) -> aesim_config:get(Sim, ver_low_shard).

cfg_unv_bucket_count(Sim) -> aesim_config:get(Sim, unv_bucket_count).

cfg_unv_bucket_size(Sim) -> aesim_config:get(Sim, unv_bucket_size).

cfg_unv_high_shard(Sim) -> aesim_config:get(Sim, unv_high_shard).

cfg_unv_low_shard(Sim) -> aesim_config:get(Sim, unv_low_shard).

cfg_unv_max_refs(Sim) -> aesim_config:get(Sim, unv_max_refs).

cfg_eviction_skew(Sim) -> aesim_config:get(Sim, eviction_skew).

cfg_verified_prob(Sim) -> aesim_config:get(Sim, verified_prob).
