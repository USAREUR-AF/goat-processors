%% The four functions and the one shape of their entry point (spec/README.md
%% "What every function shares"; spec/vector-format.md). Every function
%% module implements this behaviour:
%%   load_pack(Dir) -> {ok, Pack} | {error, Why}
%%   new(Pack) -> State
%%   ingest(Report, State) -> {Events, Trace, State}
%%   tick(NowMs, State) -> {Events, Trace, State}
%%   snapshot(State) -> map()
%% and parses a pack.def text with its pack module's parse/1. The table
%% below is the one place that names them.
-module(io_engine).
-export([functions/0, module/1, pack_parser/1, run/3, step/3]).

-callback load_pack(file:filename()) -> {ok, map()} | {error, term()}.
-callback new(map()) -> map().
-callback ingest(map(), map()) -> {list(), list(), map()}.
-callback tick(integer(), map()) -> {list(), list(), map()}.
-callback snapshot(map()) -> map().

%% Function name => {engine module, pack module}.
functions() ->
    #{<<"correlate">> => {correlate, correlate_pack},
      <<"filter">> => {filter, filter_pack},
      <<"fuse">> => {fuse, fuse_pack},
      <<"quality">> => {quality, quality_pack}}.

module(Function) ->
    case maps:find(Function, functions()) of
        {ok, {Mod, _}} -> {ok, Mod};
        error -> error
    end.

pack_parser(Function) ->
    {_, PackMod} = maps:get(Function, functions()),
    fun PackMod:parse/1.

%% One step: {ingest, Report} or {tick, NowMs}.
step(Mod, {ingest, Report}, St) -> Mod:ingest(Report, St);
step(Mod, {tick, Now}, St) -> Mod:tick(Now, St).

%% Every step in order: {[{Events, Trace}], FinalState}.
run(Mod, Steps, St0) -> run(Mod, Steps, St0, []).

run(_Mod, [], St, Acc) -> {lists:reverse(Acc), St};
run(Mod, [S | Rest], St0, Acc) ->
    {Events, Trace, St1} = step(Mod, S, St0),
    run(Mod, Rest, St1, [{Events, Trace} | Acc]).
