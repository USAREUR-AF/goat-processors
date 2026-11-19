%% Runs every quality scenario vector (packs/quality-*/vectors/) and load
%% vector (spec/quality-load-vectors/) with the comparison of
%% spec/vector-format.md, printing the path of the first mismatch.
-module(quality_vectors).
-export([main/1]).

main([Root]) ->
    Scenarios = lists:sort(filelib:wildcard(filename:join(Root, "packs/quality-*/vectors/*.json"))),
    Loads = lists:sort(filelib:wildcard(filename:join(Root, "spec/quality-load-vectors/*.json"))),
    Results = [scenario(Root, F) || F <- Scenarios] ++ [load(F) || F <- Loads],
    Failed = [R || R <- Results, R =/= ok],
    io:format("quality: ~b vectors, ~b passed, ~b failed~n",
              [length(Results), length(Results) - length(Failed), length(Failed)]),
    halt(case Failed of [] -> 0; _ -> 1 end).

read(File) ->
    {ok, Bin} = file:read_file(File),
    json:decode(Bin).

%% Scenario vector: each step's events and trace, then the final snapshot.
scenario(Root, File) ->
    V = read(File),
    Dir = filename:join([Root, "packs", maps:get(<<"pack">>, V)]),
    {ok, Pack} = quality:load_pack(Dir),
    Result = steps(maps:get(<<"steps">>, V), 0, quality:new(Pack), V),
    correlator_vectors:report(maps:get(<<"name">>, V), Result).

steps([], _I, St, V) ->
    correlator_vectors:compare(quality:snapshot(St), maps:get(<<"snapshot">>, V), "snapshot");
steps([Step | Rest], I, St0, V) ->
    {Events, Trace, St1} =
        case Step of
            #{<<"ingest">> := Report} -> quality:ingest(Report, St0);
            #{<<"tick">> := Now} -> quality:tick(Now, St0)
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
    V = read(File),
    Got = case quality_pack:parse(maps:get(<<"pack_def">>, V)) of
              {ok, _} -> false;
              {error, _} -> true
          end,
    correlator_vectors:report(maps:get(<<"name">>, V),
                              correlator_vectors:compare(Got, maps:get(<<"expect_error">>, V),
                                                         "expect_error")).
