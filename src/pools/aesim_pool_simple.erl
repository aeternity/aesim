-module(aesim_pool_simple).

%% @doc Simple pool behaviour.
%%  - Adds all identified peers to the pool.

-behaviour(aesim_pool).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% Behaviour aesim_pool callback functions
-export([parse_options/2]).
-export([pool_new/2]).
-export([pool_select/4]).
-export([pool_gossip/5]).
-export([pool_handle_event/5]).
-export([report/4]).

%=== BEHAVIOUR aesim_pool CALLBACK FUNCTIONS ===================================

parse_options(_Opts, Sim) -> Sim.

pool_new(_Context, Sim) ->
  {#{}, Sim}.

pool_select(State, Exclude, _Context, Sim) ->
  case aesim_utils:rand_pick(1, maps:keys(State), Exclude) of
    [] -> {undefined, Sim};
    [PeerId] -> {PeerId, Sim}
  end.

pool_gossip(State, all, Exclude, _Context, Sim) ->
  {maps:keys(maps:without(Exclude, State)), Sim};
pool_gossip(State, Count, Exclude, _Context, Sim) ->
  {aesim_utils:rand_pick(Count, maps:keys(State), Exclude), Sim}.

pool_handle_event(State, peer_identified, PeerId, Context, Sim) ->
  on_peer_identified(State, PeerId, Context, Sim);
pool_handle_event(_State, _Name, _Params, _Context, _Sim) -> ignore.

report(State, _Type, _Context, _Sim) ->
  #{verified_count => maps:size(State),
    unverified_count => 0}.

%=== INTERNAL FUNCTIONS ========================================================

%--- EVENT FUNCTIONS -----------------------------------------------------------

on_peer_identified(State, PeerId, Context, Sim) ->
  case maps:find(PeerId, State) of
    {ok, _} -> ignore;
    error ->
      #{node_id := NodeId} = Context,
      Sim2 = aesim_metrics:inc(NodeId, [pool, verified], 1, Sim),
      {State#{PeerId => true}, Sim2}
  end.
