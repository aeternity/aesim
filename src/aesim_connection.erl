-module(aesim_connection).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== BEHAVIOUR DEFINITION ======================================================

-callback parse_options(Opts, Sim)
  -> Sim
  when Opts :: map(),
       Sim :: sim().

-callback conn_new(Context, Sim)
  -> {State, Sim}
  when Context :: context(),
       State :: term(),
       Sim :: sim().

-callback conn_connect(State, Context, Sim)
  -> {State, Delay, Opts, Sim}
  when State :: term(),
       Context :: context(),
       Sim :: sim(),
       Delay :: delay(),
       Opts :: term().

-callback conn_accept(State, Opts, Context, Sim)
  -> {accept, State, Delay, Sim} | {reject, Delay, Sim}
  when State :: term(),
       Opts :: term(),
       Context :: context(),
       Sim :: sim(),
       Delay :: delay().

-callback conn_reject(State, Context, Sim)
  -> {Delay, Sim}
  when State :: term(),
       Context :: context(),
       Sim :: sim(),
       Delay :: delay().

-callback conn_disconnect(State, Context, Sim)
  -> {Delay, Sim}
  when State :: term(),
       Context :: context(),
       Sim :: sim(),
       Delay :: delay().

-callback conn_handle_event(State, EventName, Params, Context, Sim)
  -> ignore | {State, Sim}
  when State :: term(),
       EventName :: event_name(),
       Params :: term(),
       Context :: context(),
       Sim :: sim().
