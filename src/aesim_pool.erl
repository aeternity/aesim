-module(aesim_pool).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== BEHAVIOUR DEFINITION ======================================================

-callback parse_options(Config, Opts)
  -> Config
  when Config :: map(),
       Opts :: map().

-callback pool_new(Context, Sim)
  -> {State, Sim}
  when Context :: context(),
       State :: term(),
       Sim :: sim().

-callback pool_select(State, Count, Exclude, Context, Sim)
  -> {NodeIds, Sim}
  when State :: term(),
       Count :: pos_integer(),
       Exclude :: [id()],
       Context :: context(),
       Sim :: sim(),
       NodeIds :: [id()].

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

-export([select/5]).

%=== API FUNCTIONS =============================================================

-spec select(pool(), pos_integer(), [id()], context(), sim()) -> {[id()], sim()}.
select({Mod, State}, Count, Exclude, Context, Sim) ->
  Mod:pool_select(State, Count, Exclude, Context, Sim).
