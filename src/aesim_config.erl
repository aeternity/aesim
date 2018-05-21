-module(aesim_config).

%=== INCLUDES ==================================================================

-include_lib("stdlib/include/assert.hrl").
-include("aesim_types.hrl").

%=== EXPORTS ===================================================================

-export([get/2]).
-export([parse/3, parse/4]).

%=== TYPES =====================================================================

-type opt_name() :: atom().
-type opt_type() :: string | integer | atom | time.
-type spec() :: {opt_name(), opt_type(), term()}.
-type specs() :: [spec()].

%=== API FUNCTIONS =============================================================

-spec get(sim() | map(), opt_name()) -> term().
get(#{config := Config}, Key) -> maps:get(Key, Config);
get(Config, Key) -> maps:get(Key, Config).

-spec parse(map(), map(), specs()) -> map().
parse(Config, Opts, Specs) ->
  lists:foldl(fun({Key, Type, Default}, Cfg) ->
    Cfg#{Key => parse(Opts, Key, Type, Default)}
  end, Config, Specs).

-spec parse(map(), opt_name(), opt_type(), term()) -> term().
parse(Opts, Key, Type, Default) ->
  case maps:find(Key, Opts) of
    {ok, Value} -> convert(Type, Key, Value);
    error -> Default
  end.

%=== INTERNAL FUNCTIONS ========================================================

convert(string, _Key, Value) when is_list(Value) -> Value;
convert(_Type, Key, "") -> error({bad_option, {Key, ""}});
convert(atom, _Key, Value) when is_list(Value) -> list_to_atom(Value);
convert(time, Key, Value) when is_list(Value) -> parse_time(Key, Value);
convert(integer, Key, Value) when is_list(Value) ->
  try
    list_to_integer(Value)
  catch
    _:badarg -> error({bad_option, Key, Value})
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