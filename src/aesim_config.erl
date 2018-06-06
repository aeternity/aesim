-module(aesim_config).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

-export([new/0]).
-export([get/2]).
-export([get_option/4]).
-export([parse/3, parse/4]).
-export([print_config/1]).

%=== TYPES =====================================================================

-type opt_name() :: atom().
-type opt_type() :: string | integer | integer_infinity | atom | time
                  | time_infinity | boolean | number.
-type spec() :: {opt_name(), opt_type(), term()}.
-type specs() :: [spec()].
-type option() :: {opt_type(), boolean(), term(), term()}.
-type parser_def() :: {atom(), atom()} | fun((state(), map()) -> state()).
-type parser_defs() :: [parser_def()].

-type state() :: #{
  opt_name() => option()
}.

-export_type([state/0]).

%=== API FUNCTIONS =============================================================

-spec new() -> state().
new() ->
  #{}.

-spec get(sim(), opt_name()) -> term().
get(Sim, Key) ->
  #{config := State} = Sim,
  case maps:find(Key, State) of
    error -> error({unknown_option, Key});
    {ok, {_, _, _, Value}} -> Value
  end.

-spec parse(sim(), map(), specs()) -> sim().
parse(Sim, Opts, Specs) ->
  parse(Sim, Opts, Specs, []).

-spec parse(sim(), map(), specs(), parser_defs()) -> sim().
parse(Sim, Opts, Specs, ParserFuns) ->
  #{config := State} = Sim,
  State2 = lists:foldl(fun
    ({Key, Type, Default}, St) ->
      {IsDefault, Source, Value} = get_option(Opts, Key, Type, Default),
      add_config(St, Key, Type, IsDefault, Source, Value)
  end, State, Specs),
  Sim2 = Sim#{config := State2},
  lists:foldl(fun
    (F, S) when is_function(F) -> F(Opts, S);
    ({Key, FunName}, S) ->
      Mod = get(S, Key),
      Mod:FunName(Opts, S)
  end, Sim2, ParserFuns).

-spec print_config(sim()) -> ok.
print_config(Sim) ->
  #{config := State} = Sim,
  lists:foreach(fun({N, {T, D, S, _}}) ->
    DefStr = if D -> "(default)"; true -> "" end,
    aesim_simulator:print("~-22s: ~27s ~-17w ~9s~n", [N, S, T, DefStr], Sim)
  end, lists:keysort(1, maps:to_list(State))).

%=== INTERNAL FUNCTIONS ========================================================

add_config(State, Name, Type, IsDefault, Option, Value) ->
  Source = convert(string, Name, Option),
  case maps:find(Name, State) of
    error ->
      State#{Name => {Type, IsDefault, Source, Value}};
    {ok, {_, true, _, _}} ->
      State#{Name => {Type, IsDefault, Source, Value}};
    {ok, _} ->
      State
  end.

get_option(Opts, Key, Type, Default) ->
  case maps:find(Key, Opts) of
    {ok, Value} -> {false, Value, convert(Type, Key, Value)};
    error -> {true, Default, convert(Type, Key, Default)}
  end.

convert(string, _Key, Value) when is_list(Value) -> Value;
convert(_Type, Key, "") -> error({bad_option, {Key, ""}});
convert(atom, _Key, Value) when is_atom(Value) -> Value;
convert(integer, _Key, Value) when is_integer(Value) -> Value;
convert(number, _Key, Value) when is_number(Value) -> Value;
convert(boolean, _Key, "true") -> true;
convert(boolean, _Key, "false") -> false;
convert(boolean, _Key, "1") -> true;
convert(boolean, _Key, "0") -> false;
convert(boolean, _Key, true) -> true;
convert(boolean, _Key, false) -> false;
convert(boolean, _Key, 1) -> true;
convert(boolean, _Key, 0) -> false;
convert(integer_infinity, _Key, Value) when is_integer(Value) -> Value;
convert(integer_infinity, _Key, infinity) -> infinity;
convert(integer_infinity, _Key, "infinity") -> infinity;
convert(time, _Key, Value) when is_integer(Value), Value >= 0 -> Value;
convert(time_infinity, _Key, Value) when is_integer(Value), Value >= 0 -> Value;
convert(time_infinity, _Key, infinity) -> infinity;
convert(time_infinity, _Key, "infinity") -> infinity;
convert(string, _Key, Value) when is_atom(Value) ->
  atom_to_list(Value);
convert(string, _Key, Value) when is_integer(Value) ->
  integer_to_list(Value);
convert(string, _Key, Value) when is_number(Value) ->
  aesim_utils:format("~w", [Value]);
convert(atom, _Key, Value) when is_list(Value) ->
  list_to_atom(Value);
convert(time, Key, Value) when is_list(Value) ->
  parse_time(Key, Value);
convert(time_infinity, Key, Value) when is_list(Value) ->
  parse_time(Key, Value);
convert(Type, Key, Value)
 when is_list(Value), Type =:= integer orelse Type =:= integer_infinity  ->
  try
    list_to_integer(Value)
  catch
    _:badarg -> error({bad_option, Key, Value})
  end;
convert(number, Key, Value) ->
  try
    list_to_integer(Value)
  catch
    _:badarg ->
      try
        list_to_float(Value)
      catch
        _:badarg ->
          error({bad_option, Key, Value})
      end
  end;
convert(_Type, Key, Value) ->
  error({bad_option, Key, Value}).

parse_time(Key, Value) -> parse_days({Key, Value}, Value, 0).

parse_days(Original, "", _Acc) -> error({bad_option, Original});
parse_days(Original, Value, Acc) ->
  case re:run(Value, "^([0-9]*)d(.*)$", [{capture, all_but_first, list}]) of
    nomatch -> parse_hours(Original, Value, Acc);
    {match, [Days, Rest]} ->
      Acc2 = Acc + list_to_integer(Days) * 24 * 60 * 60 * 1000,
      parse_hours(Original, Rest, Acc2)
  end.

parse_hours(_Original, "", Acc) -> Acc;
parse_hours(Original, Value, Acc) ->
  case re:run(Value, "^([0-9]*)h(.*)$", [{capture, all_but_first, list}]) of
    nomatch -> parse_minutes(Original, Value, Acc);
    {match, [Hours, Rest]} ->
      Acc2 = Acc + list_to_integer(Hours) * 60 * 60 * 1000,
      parse_minutes(Original, Rest, Acc2)
  end.

parse_minutes(_Original, "", Acc) -> Acc;
parse_minutes(Original, Value, Acc) ->
  case re:run(Value, "^([0-9]*)m(.*)$", [{capture, all_but_first, list}]) of
    nomatch -> parse_seconds(Original, Value, Acc);
    {match, [Minutes, Rest]} ->
      Acc2 = Acc + list_to_integer(Minutes) * 60 * 1000,
      parse_seconds(Original, Rest, Acc2)
  end.

parse_seconds(_Original, "", Acc) -> Acc;
parse_seconds(Original, Value, Acc) ->
  case re:run(Value, "^([0-9]*)s(.*)$", [{capture, all_but_first, list}]) of
    nomatch -> parse_milliseconds(Original, Value, Acc);
    {match, [Seconds, Rest]} ->
      Acc2 = Acc + list_to_integer(Seconds) * 1000,
      parse_milliseconds(Original, Rest, Acc2)
  end.

parse_milliseconds(_Original, "", Acc) -> Acc;
parse_milliseconds(Original, Value, Acc) ->
  case re:run(Value, "^([0-9]*)$", [{capture, all_but_first, list}]) of
    nomatch -> error({bad_option, Original});
    {match, [Milliseconds]} ->
      Acc + list_to_integer(Milliseconds)
  end.