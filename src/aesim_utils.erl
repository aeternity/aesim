-module(aesim_utils).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").

%=== EXPORTS ===================================================================

-export([print/2]).
-export([format/2]).
-export([format_time/1]).
-export([rand/1, rand/2]).
-export([rand_take/1, rand_take/2]).
-export([rand_pick/1, rand_pick/2, rand_pick/3]).
-export([list_add_new/2]).

%=== API FUNCTIONS =============================================================

-spec print(string(), [term()]) -> ok.
print(Format, Params) ->
  io:format(Format, Params).

-spec format(string(), [term()]) -> string().
format(Format, Params) ->
  lists:flatten(io_lib:format(Format, Params)).

-spec format_time(non_neg_integer()) -> string().
format_time(Miliseconds) ->
  Sec = Miliseconds div 1000,
  Min = Sec div 60,
  Hour = Min div 60,
  Args = [Hour, Min rem 60, Sec rem 60, Miliseconds rem 1000],
  format("~bh~2.10.0bm~2.10.0bs~3.10.0b", Args).

%% Returns X where 0 <= X < N
-spec rand(pos_integer()) -> pos_integer().
rand(N) -> rand:uniform(N) - 1.

%% Returns X where N <= X < M
-spec rand(pos_integer(), pos_integer()) -> pos_integer().
rand(N, M) -> N + rand:uniform(M - N) - 1.

-spec rand_take(list()) -> {term(), list()}.
rand_take(Col) when is_list(Col)->
  {L1, [R | L2]} = lists:split(rand(length(Col)), Col),
  {R, L1 ++ L2}.

-spec rand_take(pos_integer(), list()) -> {[term()], list()}.
rand_take(1, Col) when is_list(Col) ->
  {Item, L} = rand_take(Col),
  {[Item], L};
rand_take(N, Col) when is_list(Col), N > 1 ->
  {Item, L1} = rand_take(Col),
  {Items, L2} = rand_take(N - 1, L1),
  {[Item | Items], L2}.

-spec rand_pick(list()) -> term().
rand_pick(Col) when is_list(Col) -> lists:nth(1 + rand(length(Col)), Col).

-spec rand_pick(pos_integer(), list(), list()) -> [term()].
rand_pick(N, Col) when is_list(Col), N > 0 ->
  {Items, _} = rand_take(N, Col),
  Items.

%% Really basic implementation....
-spec rand_pick(pos_integer(), list()) -> [term()].
rand_pick(_, [], _) -> [];
rand_pick(0, _, _) -> [];
rand_pick(N, Col, Exclude) when is_list(Col), N > 0 ->
  {L1, [R | L2]} = lists:split(rand(length(Col)), Col),
  case lists:member(R, Exclude) of
    true -> rand_pick(N, L1 ++ L2, Exclude);
    false -> [R | rand_pick(N - 1, L1 ++ L2, Exclude)]
  end.

-spec list_add_new(term(), list()) -> list().
list_add_new(Value, List) ->
  case lists:member(Value, List) of
    false -> [Value | List];
    true -> List
  end.
