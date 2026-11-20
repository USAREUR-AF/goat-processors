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
-export([functions/0, module/1, pack_parser/1, run/3, step/3, preload/1]).

-callback load_pack(file:filename()) -> {ok, map()} | {error, term()}.
-callback new(map()) -> map().
-callback ingest(map(), map()) -> {list(), list(), map()}.
-callback tick(integer(), map()) -> {list(), list(), map()}.
-callback snapshot(map()) -> map().

%% Function name => {engine module, pack module, the prefixes of the names
%% of the modules it runs (for preload/1)}.
functions() ->
    #{<<"correlate">> => {correlate, correlate_pack,
                          ["model_", "correlate", "assign", "trace_log", "trace_correlate",
                           "trace_assign", "snapshot_json", "snapshot_correlate",
                           "snapshot_assign", "io_"]},
      <<"filter">> => {filter, filter_pack,
                       ["model_report", "model_frame", "filter", "trace_filter",
                        "snapshot_filter", "io_"]},
      <<"fuse">> => {fuse, fuse_pack,
                     ["model_report", "model_frame", "model_kalman", "fuse", "trace_fuse",
                      "snapshot_json", "snapshot_fuse", "io_"]},
      <<"quality">> => {quality, quality_pack,
                        ["model_report", "model_frame", "model_kalman", "quality",
                         "correlate_pack", "trace_log", "trace_quality", "snapshot_json",
                         "snapshot_quality", "io_"]}}.

module(Function) ->
    case maps:find(Function, functions()) of
        {ok, {Mod, _, _}} -> {ok, Mod};
        error -> error
    end.

pack_parser(Function) ->
    {_, PackMod, _} = maps:get(Function, functions()),
    fun PackMod:parse/1.

%% Loads the modules a function runs at once, before any is called: OTP
%% prepares them in parallel and loads them in one step, which costs about
%% half the processor time of loading each on its first call (the default),
%% and less wall time. A module the prefixes miss still loads on its first
%% call. Called by the command-line entry points before they start their
%% clocks; it changes no result.
preload(Function) ->
    case maps:find(Function, functions()) of
        {ok, {_, _, Prefixes}} ->
            Dir = filename:dirname(code:which(?MODULE)),
            Names = [filename:basename(F, ".beam")
                     || F <- filelib:wildcard(filename:join(Dir, "*.beam"))],
            code:ensure_modules_loaded(
              [list_to_atom(N) || N <- Names, lists:any(fun(P) -> lists:prefix(P, N) end, Prefixes)]);
        error -> ok
    end.

%% One step: {ingest, Report} or {tick, NowMs}.
step(Mod, {ingest, Report}, St) -> Mod:ingest(Report, St);
step(Mod, {tick, Now}, St) -> Mod:tick(Now, St).

%% Every step in order: {[{Events, Trace}], FinalState}.
run(Mod, Steps, St0) -> run(Mod, Steps, St0, []).

run(_Mod, [], St, Acc) -> {lists:reverse(Acc), St};
run(Mod, [S | Rest], St0, Acc) ->
    {Events, Trace, St1} = step(Mod, S, St0),
    run(Mod, Rest, St1, [{Events, Trace} | Acc]).
