-module(aesim_metrics).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

-export([new/0]).
-export([inc/4]).

-export([name_to_list/1]).
-export([collect_nodes_metrics/1]).

%=== TYPES =====================================================================

-type metric_name() :: [atom()].

-type node_metrics() :: #{
  counters := #{metric_name() => integer()}
}.

-type state() :: #{
  nodes := #{id() => node_metrics()}
}.

-export_type([state/0]).

%=== API FUNCTIONS =============================================================

-spec new() -> state().
new() ->
  #{nodes => #{}}.

-spec inc(id(), metric_name(), integer(), sim()) -> sim().
inc(_NodeId, _Name, 0, Sim) -> Sim;
inc(NodeId, Name, Inc, Sim) ->
  #{metrics := State} = Sim,
  #{nodes := NodesMetrics} = State,
  NodeMetrics = case maps:find(NodeId, NodesMetrics) of
    error -> new_node_metrics();
    {ok, Value} -> Value
  end,
  #{counters := Counters} = NodeMetrics,
  Current = maps:get(Name, Counters, 0),
  New = Current + Inc,
  Sim#{metrics := State#{nodes := NodesMetrics#{
    NodeId => NodeMetrics#{counters := Counters#{Name => New}}}}}.


-spec name_to_list(metric_name()) -> string().
name_to_list(Name) ->
  lists:flatten(lists:join($., [atom_to_list(A) || A <- Name])).

-spec collect_nodes_metrics(sim()) -> [{metric_name(), {integer(), integer(), integer(), integer()}}].
collect_nodes_metrics(Sim) ->
  #{metrics := State} = Sim,
  #{nodes := NodesMetrics} = State,
  Metrics = lists:foldl(fun(#{counters := Counters}, Acc) ->
    maps:fold(fun(N, V, Acc2) ->
      Acc2#{N => [V | maps:get(N, Acc2, [])]}
    end, Acc, Counters)
  end, #{}, maps:values(NodesMetrics)),
  lists:map(fun({N, Values}) ->
    {N, aesim_utils:reduce_metric(Values)}
  end, maps:to_list(Metrics)).

%=== INTERNAL FUNCTIONS ========================================================

new_node_metrics() ->
  #{counters => #{}}.

