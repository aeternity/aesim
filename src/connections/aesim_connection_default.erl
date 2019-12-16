-module(aesim_connection_default).

% @doc Default connection behaviour.
%  - Accepts all the connections.
%  - Defines the default delay for connect, accept and disconnect.
%  - Optionally reject connection based on the option reject_iprob.
%    The option define the percentage of rejected connections.
%    If set to 50, 50% of connections will be rejected.

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% Behaviour aesim_connection callback functions
-export([parse_options/2]).
-export([conn_new/2]).
-export([conn_connect/3]).
-export([conn_accept/4]).
-export([conn_reject/3]).
-export([conn_disconnect/3]).
-export([conn_handle_event/5]).

%=== MACROS ====================================================================

-define(DEFAULT_CONNECT_DELAY,         100).
-define(DEFAULT_ACCEPT_DELAY,           50).
-define(DEFAULT_REJECT_DELAY,           50).
-define(DEFAULT_DISCONNECT_DELAY,       50).
-define(DEFAULT_REJECT_IPROB,            0).

%=== BEHAVIOUR aesim_connection CALLBACK FUNCTIONS =============================

parse_options(Opts, Sim) ->
  aesim_config:parse(Sim, Opts, [
    {connect_delay, integer, ?DEFAULT_CONNECT_DELAY},
    {accept_delay, integer, ?DEFAULT_ACCEPT_DELAY},
    {reject_delay, integer, ?DEFAULT_REJECT_DELAY},
    {disconnect_delay, integer, ?DEFAULT_DISCONNECT_DELAY},
    {reject_iprob, integer, ?DEFAULT_REJECT_IPROB}
  ]).

conn_new(_Context, Sim) ->
  {#{}, Sim}.

conn_connect(State, _Context, Sim) ->
  {State, cfg_connect_delay(Sim), [], Sim}.

conn_accept(State, _Opts, _Context, Sim) ->
  case cfg_reject_iprob(Sim) of
    0 ->
      {accept, State, cfg_accept_delay(Sim), Sim};
    IProb ->
      case aesim_utils:rand(100) + 1 of
        N when N =< IProb ->
              {reject, cfg_reject_delay(Sim), Sim};
        _ ->
              {accept, State, cfg_accept_delay(Sim), Sim}
      end
  end.

conn_reject(_State, _Context, Sim) ->
  {cfg_reject_delay(Sim), Sim}.

conn_disconnect(_State, _Context, Sim) ->
  {cfg_disconnect_delay(Sim), Sim}.

conn_handle_event(_State, _Name, _Params, _Context, _Sim) -> ignore.

%=== INTERNAL FUNCTIONS ========================================================

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_connect_delay(Sim) -> aesim_config:get(Sim, connect_delay).

cfg_accept_delay(Sim) -> aesim_config:get(Sim, accept_delay).

cfg_reject_delay(Sim) -> aesim_config:get(Sim, reject_delay).

cfg_disconnect_delay(Sim) -> aesim_config:get(Sim, disconnect_delay).

cfg_reject_iprob(Sim) -> aesim_config:get(Sim, reject_iprob).
