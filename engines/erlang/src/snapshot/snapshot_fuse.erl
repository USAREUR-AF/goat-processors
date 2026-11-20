%% Snapshot of fuse (fuse.md "Snapshot").
-module(snapshot_fuse).
-export([snapshot/1]).

snapshot(#{ref := Ref, entities := Ents}) ->
    #{<<"ref">> => snapshot_json:ref(Ref),
      <<"entities">> =>
          maps:map(fun(_K, #{time := T, group := G, filter := Fl, report := R}) ->
                           #{<<"last_time_ms">> => T, <<"group">> => G,
                             <<"filter">> => snapshot_json:filter(Fl),
                             <<"report">> => R}
                   end, Ents)}.
