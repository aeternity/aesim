-module(aesim_pool).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== BEHAVIOUR DEFINITION ======================================================

-callback parse_options(Opts, Sim)
  -> Sim
  when Opts :: map(),
       Sim :: sim().

-callback pool_new(Context, Sim)
  -> {State, Sim}
  when Context :: context(),
       State :: term(),
       Sim :: sim().

-callback pool_init(State, Trusted, Context, Sim)
  -> {State, Sim}
  when State :: term(),
       Trusted :: neighbours(),
       Context :: context(),
       Sim :: sim().

-callback pool_count(State, CounterName)
  -> non_neg_integer()
  when State :: term(),
       CounterName :: pool_counters().

-callback pool_select(State, ExcludePeerIds, ExcludePeerGroups, Context, Sim)
  -> {selected, PeerId, Sim}
   | {retry, NextTryTime, Sim}
   | {unavailable, Sim}
  when State :: term(),
       ExcludePeerIds :: [id()],
       ExcludePeerGroups :: [address_group()],
       Context :: context(),
       Sim :: sim(),
       PeerId :: id(),
       NextTryTime :: sim_time() | undefined.

-callback pool_gossip(State, Count | all, Exclude, Context, Sim)
  -> {[PeerId], Sim}
  when State :: term(),
       Count :: pos_integer(),
       Exclude :: [id()],
       Context :: context(),
       Sim :: sim(),
       PeerId :: id().

-callback pool_handle_event(State, EventName, Params, Context, Sim)
  -> ignore | {State, Sim}
  when State :: term(),
       EventName :: event_name(),
       Params :: term(),
       Context :: context(),
       Sim :: sim().

-callback report(State, Type, Context, Sim)
  -> map()
  when State :: term(),
       Type :: report_type(),
       Context :: context(),
       Sim :: sim().

%=== EXPORTS ===================================================================

%% API function for any callback modules
-export([count/2]).
-export([select/5]).
-export([gossip/5]).

%% Utility function for pool callback modules
-export([filter_peers/7]).

%=== TYPES =====================================================================

-type pool_counters() :: all | verified | unverified.
-type retry_backoff_fun() :: fun((non_neg_integer(), sim_time()) -> sim_time() | undefined).

%=== API FUNCTIONS =============================================================

-spec count(pool(), pool_counters()) -> non_neg_integer().
count({Mod, State}, CounterName) ->
  Mod:pool_count(State, CounterName).

-spec select(pool(), [id()], [address_group()], context(), sim())
  -> {selected, id(), sim()} | {retry, sim_time(), sim()} | {unavailable, sim()}.
select({Mod, State}, ExcludePeerIds, ExcludePeerGroups, Context, Sim) ->
  Mod:pool_select(State, ExcludePeerIds, ExcludePeerGroups, Context, Sim).

-spec gossip(pool(), pos_integer(), [id()], context(), sim()) -> {[id()], sim()}.
gossip({Mod, State}, Count, Exclude, Context, Sim) ->
  Mod:pool_gossip(State, Count, Exclude, Context, Sim).


%--- UTILITY FUNCTIONS ---------------------------------------------------------

%% Filter out the peers that are waiting for retrying and schedule peer removal.
%% Exclude given peer ids and given address groups from the returned list.
-spec filter_peers([id()], [id()], [address_group()], pos_integer(),
                   retry_backoff_fun(), context(), sim())
  -> {sim_time() | undefined, [id()], sim()}.
filter_peers(Ids, ExcludePeerIds, ExcludePeerGroups, MaxRetries, BackOffTimeFun, Context, Sim0) ->
  #{node_id := NodeId, peers := Peers} = Context,
  #{time := Now} = Sim0,
  lists:foldl(fun(PeerId, {Min, Acc, Sim}) ->
    #{PeerId := Peer} = Peers,
    #{type := Type,
      addr := Addr,
      retry_count := RetryCount,
      retry_time := RetryTime
    } = Peer,
    AddrGroup = aesim_utils:address_group(Addr),
    GroupIsExcluded = lists:member(AddrGroup, ExcludePeerGroups),
    PeerIsExcluded = lists:member(PeerId, ExcludePeerIds),
    case GroupIsExcluded or PeerIsExcluded of
      true -> {Min, Acc, Sim};
      false ->
        case {Type, RetryCount, BackOffTimeFun(RetryCount, RetryTime)} of
          {_, 0, _} ->
            % Peer not currently retrying
            {Min, [PeerId | Acc], Sim};
          {T, R, N} when R > MaxRetries, T =/= trusted ->
            % Peer expired the maximum retryes and is not trusted
            Sim2 = aesim_node:async_peer_expired(NodeId, PeerId, Sim),
            {safe_min(Min, N), Acc, Sim2};
          {_, _, NextRetryTime} when NextRetryTime =< Now ->
            % Peer is scheduled for retry
            {Min, [PeerId | Acc], Sim};
          {_, _R, N} ->
            % Peer is not yet ready to retry
            {safe_min(Min, N), Acc, Sim}
        end
    end
  end, {undefined, [], Sim0}, Ids).

%=== INTERNAL FUNCTIONS ========================================================

safe_min(undefined, Value2) -> Value2;
safe_min(Value1, Value2) -> min(Value1, Value2).
