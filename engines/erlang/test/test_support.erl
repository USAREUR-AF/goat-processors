%% Helpers the tests share: the repository root, every scenario vector of a
%% function with its pack, a seeded generator, and running the steps.
-module(test_support).
-export([main/0, coverage/1, test_modules/0]).
-export([root/0, scenarios/1, scenarios/0, pack_dirs/1, load/2, run/2, run_from/3, steps/1,
         rand_state/1, uniform/2, pick/2, shuffle/2, budget/0]).

root() ->
    case os:getenv("GOAT_ROOT") of
        false ->
            Here = filename:dirname(code:which(?MODULE)),
            filename:absname(filename:join([Here, "..", "..", "..", ".."]));
        R -> R
    end.

functions() -> [<<"correlate">>, <<"filter">>, <<"fuse">>, <<"quality">>].

%% [{Function, Mod, PackDir, VectorFile}] for every scenario vector.
scenarios() -> lists:append([scenarios(F) || F <- functions()]).

scenarios(Function) ->
    {ok, Mod} = io_engine:module(Function),
    Files = lists:sort(filelib:wildcard(
                         filename:join(root(), "packs/" ++ binary_to_list(Function)
                                       ++ "-*/vectors/*.json"))),
    [{Function, Mod, filename:dirname(filename:dirname(F)), F} || F <- Files].

pack_dirs(Function) ->
    lists:sort(filelib:wildcard(filename:join(root(), "packs/" ++ binary_to_list(Function) ++ "-*"))).

load(Mod, Dir) ->
    {ok, Pack} = Mod:load_pack(Dir),
    Mod:new(Pack).

steps(File) -> io_vectors:steps(io_vectors:read(File)).

%% {[{Events, Trace}], Snapshot} of every step from a new engine.
run(Mod, {Dir, Steps}) ->
    {Out, St} = io_engine:run(Mod, Steps, load(Mod, Dir)),
    {Out, Mod:snapshot(St)}.

%% The same from a given state.
run_from(Mod, St0, Steps) ->
    {Out, St} = io_engine:run(Mod, Steps, St0),
    {Out, Mod:snapshot(St)}.

%% A seeded generator: the state is threaded, never global.
rand_state(Seed) -> rand:seed_s(exsss, Seed).

%% {Integer in 1..N, State}.
uniform(N, S) -> rand:uniform_s(N, S).

pick(List, S0) ->
    {I, S1} = uniform(length(List), S0),
    {lists:nth(I, List), S1}.

shuffle(List, S0) ->
    {Keyed, S} = lists:foldl(fun(X, {Acc, Si}) ->
                                     {R, Sj} = rand:uniform_s(Si),
                                     {[{R, X} | Acc], Sj}
                             end, {[], S0}, List),
    {[X || {_, X} <- lists:sort(Keyed)], S}.

%% Fuzz iterations per target: GOAT_FUZZ_ITERATIONS, or 1500.
budget() ->
    case os:getenv("GOAT_FUZZ_ITERATIONS") of
        false -> 1500;
        N -> list_to_integer(N)
    end.

%% ---------------------------------------------------------------- runners

%% The test modules: every module of test/ebin whose name ends in _tests.
test_modules() ->
    Dir = filename:dirname(code:which(?MODULE)),
    lists:sort([list_to_atom(filename:basename(F, ".beam"))
                || F <- filelib:wildcard(filename:join(Dir, "*_tests.beam"))]).

%% run_tests: every test module; halts 0 when all pass.
main() ->
    Result = eunit:test(test_modules(), []),
    halt(case Result of ok -> 0; _ -> 1 end).

%% coverage [Floor]: cover-compile src/, run the vectors and the tests, print
%% line coverage per module and in total, halt non-zero below Floor.
coverage([FloorText]) ->
    Floor = list_to_float(case lists:member($., FloorText) of
                              true -> FloorText;
                              false -> FloorText ++ ".0"
                          end),
    Src = filename:join(root(), "engines/erlang/src"),
    {ok, _} = cover:start(),
    Compiled = lists:append([cover:compile_directory(D, [{i, Src}])
                             || D <- lists:sort(filelib:wildcard(filename:join(Src, "*"))),
                                filelib:is_dir(D)]),
    Mods = lists:sort([M || {ok, M} <- Compiled]),
    [] = [E || E = {error, _} <- Compiled],
    Vectors = lists:append([io_vectors:results(F, root())
                            || F <- [<<"correlate">>, <<"filter">>, <<"fuse">>, <<"quality">>]]),
    VectorsOk = lists:all(fun(R) -> R =:= ok end, Vectors),
    TestsOk = eunit:test(test_modules(), []) =:= ok,
    Rows = [begin {ok, {M, {C, N}}} = cover:analyse(M, coverage, module), {M, C, N} end
            || M <- Mods],
    [io:format("~-24s ~6.1f %  (~b of ~b lines)~n", [M, pct(C, C + N), C, C + N])
     || {M, C, N} <- Rows],
    Uncovered = [io_lib:format("~s:~b", [M, L])
                 || M <- Mods, {ok, Ls} <- [cover:analyse(M, coverage, line)],
                    {{_, L}, {0, 1}} <- Ls, L > 0],
    io:format("not covered: ~s~n", [lists:join(" ", Uncovered)]),
    Covered = lists:sum([C || {_, C, _} <- Rows]),
    Lines = lists:sum([C + N || {_, C, N} <- Rows]),
    Total = pct(Covered, Lines),
    io:format("line coverage: ~.1f % (~b of ~b lines, ~b modules); floor ~.1f %~n",
              [Total, Covered, Lines, length(Rows), Floor]),
    io:format("vectors: ~b, all pass: ~p; tests pass: ~p~n", [length(Vectors), VectorsOk, TestsOk]),
    halt(case VectorsOk andalso TestsOk andalso Total >= Floor of true -> 0; false -> 1 end).

pct(_, 0) -> 100.0;
pct(C, T) -> 100 * C / T.
