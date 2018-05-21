-module(aesim_connection_default).

% @doc Default connection behaviour.
%  - Accepts all the connections.
%  - Defines the default delay for connect, accept and disconnect.

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

%% Behaviour aesim_connection callback functions
-export([parse_options/2]).
-export([conn_new/2]).
-export([conn_connect/3]).
-export([conn_accept/4]).
-export([conn_disconnect/3]).
-export([conn_handle_event/5]).

%=== MACROS ====================================================================

-define(DEFAULT_CONNECT_DELAY,    30).
-define(DEFAULT_ACCEPT_DELAY,     10).
-define(DEFAULT_REJECT_DELAY,     10).
-define(DEFAULT_DISCONNECT_DELAY, 10).

%=== BEHAVIOUR aesim_connection CALLBACK FUNCTIONS =============================

parse_options(Config, Opts) ->
  aesim_config:parse(Config, Opts, [
    {connect_delay, integer, ?DEFAULT_CONNECT_DELAY},
    {accept_delay, integer, ?DEFAULT_ACCEPT_DELAY},
    {reject_delay, integer, ?DEFAULT_REJECT_DELAY},
    {disconnect_delay, integer, ?DEFAULT_DISCONNECT_DELAY}
  ]).

conn_new(_Context, Sim) ->
  {#{}, Sim}.

conn_connect(State, _Context, Sim) ->
  {State, cfg_connect_delay(Sim), [], Sim}.

conn_accept(State, _Opts, _Context, Sim) ->
  {accept, State, cfg_accept_delay(Sim), Sim}.

conn_disconnect(_State, _Context, Sim) ->
  {cfg_disconnect_delay(Sim), Sim}.

conn_handle_event(_State, _Name, _Params, _Context, _Sim) -> ignore.

%=== INTERNAL FUNCTIONS ========================================================

%--- CONFIG FUNCTIONS ----------------------------------------------------------

cfg_connect_delay(Config) -> aesim_config:get(Config, connect_delay).

cfg_accept_delay(Config) -> aesim_config:get(Config, accept_delay).

% cfg_reject_delay(Config) -> aesim_config:get(Config, reject_delay).

cfg_disconnect_delay(Config) -> aesim_config:get(Config, disconnect_delay).
