-module(aesim_events).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

-export([new/0]).
-export([post/5, post/6]).
-export([cancel/2]).
-export([cancel_tagged/2]).

-export([size/1]).
-export([next/1]).

-export([print_events/1]).
-export([print_summary/1]).

%=== TYPES =====================================================================

-type event() :: {event_tag(), event_addr(), event_name(), term()}.

-type state() :: #{
  next_id := event_id(),
  tags := #{event_tag() => [event_ref()]},
  queue_size => non_neg_integer(),
  queue => queue:queue(),
  sched := gb_trees:tree(event_ref(), event())
}.

%=== API FUNCTIONS =============================================================

-spec new() -> state().
new() ->
  #{next_id => 1,
    tags => #{},
    queue_size => 0,
    queue => queue:new(),
    sched => gb_trees:empty()
  }.

-spec post(delay(), event_addr(), event_name(), term(), sim()) -> {event_ref(), sim()}.
post(Delay, Target, Name, Params, Sim) ->
  post(Delay, Target, Name, Params, undefined, Sim).

-spec post(delay(), event_addr(), event_name(), term(), event_tag() | undefined, sim()) -> {event_ref(), sim()}.
post(0, Target, Name, Params, _Tag, Sim) ->
  #{events := State} = Sim,
  State2 = queue_event(State, Target, Name, Params),
  {undefined, Sim#{events := State2}};
post(Delay, Target, Name, Params, Tag, Sim) ->
  #{time := Time, events := State} = Sim,
  {State2, Ref} = schedule_event(State, Time + Delay, Target, Name, Params, Tag),
  {Ref, Sim#{events := State2}}.

-spec cancel(event_ref(), sim()) -> sim().
cancel(EventRef, Sim) ->
  #{events := State} = Sim,
  Sim#{events := del_event(State, EventRef)}.

-spec cancel_tagged(event_tag(), sim()) -> sim().
cancel_tagged(Tag, Sim) ->
  #{events := State} = Sim,
  Sim#{events := del_tagged(State, Tag)}.

-spec size(sim()) -> non_neg_integer().
size(#{events := State}) ->
  #{queue_size := Size, sched := Events} = State,
  Size + gb_trees:size(Events).

-spec next(sim()) -> empty | {sim_time(), event_addr(), event_name(), term(), sim()}.
next(Sim) ->
  #{time := Time, events := State} = Sim,
  case take_queued(State) of
    {State2, Target, Name, Params} ->
      {Time, Target, Name, Params, Sim#{events := State2}};
    empty ->
      case take_scheduled(State) of
        empty -> empty;
        {State2, EventTime, Target, Name, Params} ->
          {EventTime, Target, Name, Params, Sim#{events := State2}}
      end
  end.

-spec print_events(sim()) -> ok.
print_events(Sim) -> dump_events(next(Sim)).

-spec print_summary(sim()) -> ok.
print_summary(Sim) -> dump_summary(#{}, next(Sim)).

%=== INTERNAL FUNCTIONS ========================================================

dump_events(empty) -> ok;
dump_events({NextTime, EAddr, EName, _Params, Sim}) ->
  TimeStr = aesim_utils:format_time(NextTime),
  aesim_utils:print("~13s ~-13s ~w~n", [TimeStr, EName, EAddr]),
  dump_events(next(Sim)).

dump_summary(Acc, {_NextTime, EAddr, EName, _Params, Sim}) ->
  {C, Ts} = maps:get(EName, Acc, {0, #{}}),
  dump_summary(Acc#{EName => {C + 1, Ts#{EAddr => true}}}, next(Sim));
dump_summary(Acc, empty) ->
  lists:foreach(fun({N, {C, Ts}}) ->
    aesim_utils:print("~-13s : ~6b event(s) for ~4b target(s)~n",
                      [N, C, maps:size(Ts)])
  end, maps:to_list(Acc)).

queue_event(State, Target, Name, Params) ->
  #{queue_size := Size, queue := Queue} = State,
  Event = {Target, Name, Params},
  State#{queue_size := Size + 1, queue := queue:in(Event, Queue)}.

take_queued(#{queue_size := 0}) -> empty;
take_queued(State) ->
  #{queue_size := Size, queue := Queue} = State,
  {{value, {Target, Name, Params}}, Queue2} = queue:out(Queue),
  {State#{queue_size := Size - 1, queue := Queue2}, Target, Name, Params}.

schedule_event(State, EventTime, Target, Name, Params, Tag) ->
  #{next_id := EventId, sched := Events, tags := Tags} = State,
  EventRef = {EventTime, EventId},
  Event = {Tag, Target, Name, Params},
  Events2 = gb_trees:insert(EventRef, Event, Events),
  Tags2 = add_tag(Tags, Tag, EventRef),
  {State#{next_id := EventId + 1, sched := Events2, tags := Tags2}, EventRef}.

take_scheduled(State) ->
  #{tags := Tags, sched := Events} = State,
  case gb_trees:is_empty(Events) of
    true -> empty;
    false ->
      {EventRef, Event, Events2} = gb_trees:take_smallest(Events),
      {EventTime, _} = EventRef,
      {Tag, Target, Name, Params} = Event,
      State2 = State#{sched := Events2, tags := del_tag(Tags, Tag, EventRef)},
      {State2, EventTime, Target, Name, Params}
  end.

del_event(State, EventRef) ->
  #{sched := Events, tags := Tags} = State,
  case gb_trees:lookup(EventRef, Events) of
    none -> State;
    {value, {Tag, _, _, _}} ->
      Events2 = gb_trees:delete(EventRef, Events),
      Tags2 = del_tag(Tags, Tag, EventRef),
      State#{sched := Events2, tags := Tags2}
  end.

del_tagged(State, Tag) ->
  #{sched := Events, tags := Tags} = State,
  case maps:take(Tag, Tags) of
    error -> State;
    {Keys, Tags2} ->
      State#{sched := gbtree_without(Keys, Events), tags := Tags2}
  end.

add_tag(Tags, undefined, _Key) -> Tags;
add_tag(Tags, Tag, Key) ->
  Keys = maps:get(Tag, Tags, []),
  maps:put(Tag, [Key | Keys], Tags).

del_tag(Tags, undefined, _Key) -> Tags;
del_tag(Tags, Tag, Key) ->
  Keys = maps:get(Tag, Tags, []),
  case lists:delete(Key, Keys) of
    [] -> maps:remove(Tag, Tags);
    Keys2 -> Tags#{Tag := Keys2}
  end.

gbtree_without(Keys, Tree) ->
  lists:foldl(fun(K, T) -> gb_trees:delete_any(K, T) end, Tree, Keys).
