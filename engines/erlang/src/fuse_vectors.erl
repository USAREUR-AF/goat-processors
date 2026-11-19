%% Runs every fuse scenario vector (packs/fuse-*/vectors/) and fuse load
%% vector (spec/fuse-load-vectors/), compared as spec/vector-format.md says.
-module(fuse_vectors).
-export([main/1]).

main([Root]) ->
    Scenarios = lists:sort(filelib:wildcard(filename:join(Root, "packs/fuse-*/vectors/*.json"))),
    Loads = lists:sort(filelib:wildcard(filename:join(Root, "spec/fuse-load-vectors/*.json"))),
    Results = [scenario(Root, F) || F <- Scenarios] ++ [load(F) || F <- Loads],
    Failed = [R || R <- Results, R =/= ok],
    io:format("fuse: ~b vectors, ~b passed, ~b failed~n",
              [length(Results), length(Results) - length(Failed), length(Failed)]),
    halt(case Failed of [] -> 0; _ -> 1 end).

%% Scenario vector: each step's events and trace, then the final snapshot.
scenario(Root, File) ->
    V = correlator_vectors:read(File),
    Pack = maps:get(<<"pack">>, V),
    {ok, P} = fuse:load_pack(filename:join([Root, "packs", Pack])),
    Result = steps(maps:get(<<"steps">>, V), 0, fuse:new(P), V),
    correlator_vectors:report(<<Pack/binary, "/", (maps:get(<<"name">>, V))/binary>>, Result).

steps([], _I, St, V) ->
    correlator_vectors:compare(fuse:snapshot(St), maps:get(<<"snapshot">>, V), "snapshot");
steps([Step | Rest], I, St0, V) ->
    {Events, Trace, St1} =
        case Step of
            #{<<"ingest">> := Report} -> fuse:ingest(Report, St0);
            #{<<"tick">> := Now} -> fuse:tick(Now, St0)
        end,
    P = lists:flatten(io_lib:format("steps[~b]", [I])),
    case correlator_vectors:compare(Events, maps:get(<<"expect">>, Step), P ++ ".expect") of
        ok ->
            case correlator_vectors:compare(Trace, maps:get(<<"trace">>, Step), P ++ ".trace") of
                ok -> steps(Rest, I + 1, St1, V);
                M -> M
            end;
        M -> M
    end.

%% Load vector: parsing pack_def fails exactly when expect_error is true.
load(File) ->
    V = correlator_vectors:read(File),
    Got = case fuse_pack:parse(maps:get(<<"pack_def">>, V)) of
              {ok, _} -> false;
              {error, _} -> true
          end,
    correlator_vectors:report(<<"fuse-load/", (maps:get(<<"name">>, V))/binary>>,
                              correlator_vectors:compare(Got, maps:get(<<"expect_error">>, V),
                                                         "expect_error")).
