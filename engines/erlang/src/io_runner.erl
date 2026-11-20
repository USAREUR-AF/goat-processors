%% The command-line runner (tools/perf/README.md "Runner contract"):
%%   run --function <correlate|filter|fuse|quality> --pack <dir> --steps <file>
%%       [--events <file>] [--trace]
%% Reads and parses the steps file, loads the pack and creates the engine,
%% then calls ingest or tick per step in order and snapshot once. Writes one
%% line of counters to standard output; diagnostics go to standard error.
%% The events file holds one JSON object per line, map keys in byte order.
-module(io_runner).
-export([main/0]).

main() ->
    Status = try run(init:get_plain_arguments())
             catch throw:{usage, Msg} -> err(Msg), 2
             end,
    halt(Status).

err(Msg) -> io:format(standard_error, "erlang runner: ~ts~n", [Msg]).

args([], Acc) -> Acc;
args(["--function", F | Rest], Acc) -> args(Rest, Acc#{function => F});
args(["--pack", P | Rest], Acc) -> args(Rest, Acc#{pack => P});
args(["--steps", S | Rest], Acc) -> args(Rest, Acc#{steps => S});
args(["--events", E | Rest], Acc) -> args(Rest, Acc#{events => E});
args(["--trace" | Rest], Acc) -> args(Rest, Acc#{trace => true});
args([A | _], _) -> throw({usage, "unknown argument " ++ A}).

engine("correlate") -> correlator;
engine("filter") -> filter;
engine("fuse") -> fuse;
engine("quality") -> quality;
engine(F) -> throw({usage, "unknown function " ++ F}).

run(Argv) ->
    Opts = args(Argv, #{trace => false}),
    [maps:is_key(K, Opts) orelse throw({usage, "missing --" ++ atom_to_list(K)})
     || K <- [function, pack, steps]],
    #{function := Function, pack := PackDir, steps := StepsFile, trace := WithTrace} = Opts,
    Mod = engine(Function),
    T0 = now_ns(),
    Steps = case catch parse_steps(StepsFile) of
                L when is_list(L) -> L;
                _ -> throw({usage, "steps file does not parse: " ++ StepsFile})
            end,
    T1 = now_ns(),
    Engine0 = case catch Mod:load_pack(PackDir) of
                  {ok, Pack} -> Mod:new(Pack);
                  Other -> throw({usage, lists:flatten(io_lib:format("pack does not load: ~ts: ~0p",
                                                                     [PackDir, Other]))})
              end,
    T2 = now_ns(),
    {Outputs, Engine} = steps(Mod, Steps, Engine0, []),
    Snapshot = Mod:snapshot(Engine),
    T3 = now_ns(),
    case Opts of
        #{events := EventsFile} -> write_events(EventsFile, Outputs, Snapshot, WithTrace);
        _ -> ok
    end,
    Counters = [{<<"engine">>, <<"erlang">>},
                {<<"function">>, list_to_binary(Function)},
                {<<"pack">>, unicode:characters_to_binary(filename:basename(PackDir))},
                {<<"steps">>, length(Steps)},
                {<<"ingest">>, length([x || {ingest, _} <- Steps])},
                {<<"tick">>, length([x || {tick, _} <- Steps])},
                {<<"events">>, lists:sum([length(E) || {E, _} <- Outputs])},
                {<<"trace_records">>, lists:sum([length(T) || {_, T} <- Outputs])},
                {<<"parse_ns">>, T1 - T0},
                {<<"load_ns">>, T2 - T1},
                {<<"run_ns">>, T3 - T2}],
    io:put_chars([json:encode(maps:from_list(Counters), fun encode/2), $\n]),
    0.

now_ns() -> erlang:monotonic_time(nanosecond).

%% The steps of a JSON object whose "steps" is a list; each step holds
%% "ingest" (a report) or "tick" (an integer now_ms); other keys are ignored.
parse_steps(File) ->
    {ok, Bin} = file:read_file(File),
    #{<<"steps">> := Steps} = json:decode(Bin),
    [case S of
         #{<<"ingest">> := R} when is_map(R) -> {ingest, R};
         #{<<"tick">> := N} when is_integer(N) -> {tick, N}
     end || S <- Steps].

steps(_Mod, [], Engine, Acc) -> {lists:reverse(Acc), Engine};
steps(Mod, [{ingest, R} | Rest], E0, Acc) ->
    {Events, Trace, E1} = Mod:ingest(R, E0),
    steps(Mod, Rest, E1, [{Events, Trace} | Acc]);
steps(Mod, [{tick, N} | Rest], E0, Acc) ->
    {Events, Trace, E1} = Mod:tick(N, E0),
    steps(Mod, Rest, E1, [{Events, Trace} | Acc]).

write_events(File, Outputs, Snapshot, WithTrace) ->
    Lines = lines(Outputs, 0, WithTrace, []),
    Last = [json:encode(#{<<"snapshot">> => Snapshot}, fun encode/2), $\n],
    ok = file:write_file(File, [Lines, Last]).

lines([], _I, _WithTrace, Acc) -> lists:reverse(Acc);
lines([{Events, Trace} | Rest], I, WithTrace, Acc) ->
    Obj0 = #{<<"step">> => I, <<"events">> => Events},
    Obj = case WithTrace of
              true -> Obj0#{<<"trace">> => Trace};
              false -> Obj0
          end,
    lines(Rest, I + 1, WithTrace, [[json:encode(Obj, fun encode/2), $\n] | Acc]).

%% JSON encoding with every object's keys in byte order, so that a file
%% depends only on the values, never on a map's internal order.
encode(M, Enc) when is_map(M) ->
    json:encode_key_value_list(lists:keysort(1, maps:to_list(M)), Enc);
encode(Other, Enc) -> json:encode_value(Other, Enc).
