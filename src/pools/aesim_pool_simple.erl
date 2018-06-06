-module(aesim_pool_simple).

%% @doc Simple pool behaviour.
%%  - Adds all identified peers to the pool.
%%  - Selects only peers that are not waiting for retry up to 7 times.
%%  - Uses exponential backoff for retry time using epoch (0.14.0) constants.
%%  - Notifies of peer expiration lazyly when selecting a peer.

-behaviour(aesim_pool).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== MACROS ====================================================================

-define(BACKOFF_TIMES, [5, 15, 30, 60, 120, 300, 600]).
-define(MAX_RETRIES, 7).

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

%=== BEHAVIOUR aesim_pool CALLBACK FUNCTIONS ===================================

parse_options(_Opts, Sim) -> Sim.

pool_new(_Context, Sim) ->
  {#{}, Sim}.

pool_init(State0, Trusted, Context, Sim0) ->
  lists:foldl(fun({PeerId, _}, {State, Sim}) ->
    add_verified(State, PeerId, Context, Sim)
  end, {State0, Sim0}, Trusted).

pool_count(State, all) -> maps:size(State);
pool_count(State, verified) -> maps:size(State);
pool_count(_State, unverified) -> 0.

pool_select(State, ExIds, ExGroups, Context, Sim) ->
  case aesim_pool:filter_peers(maps:keys(State), ExIds, ExGroups, ?MAX_RETRIES,
                               fun retry_backoff/2, Context, Sim) of
    {undefined, [], Sim2} ->
      {unavailable, Sim2};
    {NextTime, [], Sim2} ->
      {retry, NextTime, Sim2};
    {_, AvailableIds, Sim2} ->
      [PeerId] = aesim_utils:rand_pick(1, AvailableIds),
      {selected, PeerId, Sim2}
  end.

pool_gossip(State, all, Exclude, _Context, Sim) ->
  {maps:keys(maps:without(Exclude, State)), Sim};
pool_gossip(State, Count, Exclude, _Context, Sim) ->
  {aesim_utils:rand_pick(Count, maps:keys(State), Exclude), Sim}.

pool_handle_event(State, peer_identified, PeerId, Context, Sim) ->
  add_verified(State, PeerId, Context, Sim);
pool_handle_event(State, peer_expired, PeerId, Context, Sim) ->
  del_verified(State, PeerId, Context, Sim);
pool_handle_event(_State, _Name, _Params, _Context, _Sim) -> ignore.

report(State, _Type, _Context, _Sim) ->
  #{known_count => maps:size(State),
    verified_count => maps:size(State),
    unverified_count => 0}.

%=== INTERNAL FUNCTIONS ========================================================

retry_backoff(0, _) -> undefined;
retry_backoff(RetryCount, RetryTime) ->
  BackoffIndex = min(RetryCount, length(?BACKOFF_TIMES)),
  RetryTime + lists:nth(BackoffIndex, ?BACKOFF_TIMES) * 1000.

add_verified(State, PeerId, Context, Sim) ->
  case maps:find(PeerId, State) of
    {ok, _} -> State;
    error ->
      #{node_id := NodeId} = Context,
      Sim2 = aesim_metrics:inc(NodeId, [pool, known], 1, Sim),
      Sim3 = aesim_metrics:inc(NodeId, [pool, verified], 1, Sim2),
      {State#{PeerId => true}, Sim3}
  end.

del_verified(State, PeerId, Context, Sim) ->
  case maps:find(PeerId, State) of
    error -> ignore;
    {ok, _} ->
      #{node_id := NodeId} = Context,
      Sim2 = aesim_metrics:inc(NodeId, [pool, known], -1, Sim),
      Sim3 = aesim_metrics:inc(NodeId, [pool, verified], -1, Sim2),
      {maps:remove(PeerId, State), Sim3}
  end.
