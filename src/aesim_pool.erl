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

-callback pool_select(State, Exclude, Context, Sim)
  -> {undefined | PeerId, Sim}
  when State :: term(),
       Exclude :: [id()],
       Context :: context(),
       Sim :: sim(),
       PeerId :: id().

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

-export([select/4]).
-export([gossip/5]).

%=== API FUNCTIONS =============================================================

-spec select(pool(), [id()], context(), sim()) -> {undefined | id(), sim()}.
select({Mod, State}, Exclude, Context, Sim) ->
  Mod:pool_select(State, Exclude, Context, Sim).

-spec gossip(pool(), pos_integer(), [id()], context(), sim()) -> {[id()], sim()}.
gossip({Mod, State}, Count, Exclude, Context, Sim) ->
  Mod:pool_gossip(State, Count, Exclude, Context, Sim).
