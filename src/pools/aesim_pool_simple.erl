-module(aesim_pool_simple).

%% @doc Simple pool behaviour.
%%  - Adds all identified peers to the pool.
%%  - Request a connection to all peers yet when added.

-behaviour(aesim_pool).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% Behaviour aesim_pool callback functions
-export([parse_options/2]).
-export([pool_new/2]).
-export([pool_select/5]).
-export([pool_handle_event/5]).
-export([report/4]).

%=== BEHAVIOUR aesim_pool CALLBACK FUNCTIONS ===================================

parse_options(Config, _Opts) -> Config.

pool_new(_Context, Sim) ->
  {#{}, Sim}.

pool_select(State, Count, Exclude, _Context, Sim) ->
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
  %% Automatically connect to any new peer not yet connected
  #{node_id := NodeId, conns := Conns} = Context,
  case maps:is_key(PeerId, State) of
    true -> ignore;
    false ->
      State2 = State#{PeerId => true},
      case aesim_connections:has_connection(Conns, PeerId) of
        true -> {State2, Sim};
        false ->
          {_, Sim2} = aesim_node:sched_connect(0, NodeId, PeerId, Sim),
          {State2, Sim2}
      end
  end.
