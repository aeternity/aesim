-module(aesim).

-behaviour(application).

%=== EXPORTS ===================================================================

-export([main/1]).
-export([start/2]).
-export([stop/1]).

%=== API FUNCTIONS =============================================================

-spec main(term()) -> no_return().
main(Args) ->
    start_simulator(Args).

%% Dialyzer don't like we create an anonymous function that doesn't return
-dialyzer({nowarn_function, start/2}).
start(_StartType, StartArgs) ->
  {ok, spawn(fun() -> start_simulator(StartArgs) end)}.

stop(_State) -> ok.

%=== INTERNAL FUNCTIONS ========================================================

start_simulator(Args) ->
  case aesim_simulator:run(parse_options(Args)) of
    normal -> erlang:halt(0);
    _ -> erlang:halt(1)
  end.

parse_options(Args) ->
  {ok, Regex} = re:compile("^([a-z][a-zA-Z0-9_]*)=(.*)$"),
  parse_options(Args, Regex, #{}).

parse_options([], _Regex, Opts) -> Opts;
parse_options([Opt | Rest], Regex, Opts) ->
  case re:run(Opt, Regex, [{capture, all_but_first, list}]) of
    {match, [KeyStr, Value]} ->
      Key = list_to_atom(KeyStr),
      parse_options(Rest, Regex, Opts#{Key => Value});
    _ ->
      io:format(standard_error, "Invalid option: ~s~n", [Opt]),
      erlang:halt(1)
  end.
