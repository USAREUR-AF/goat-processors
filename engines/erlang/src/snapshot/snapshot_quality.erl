%% Snapshot of quality (quality.md "Snapshot").
-module(snapshot_quality).
-export([snapshot/1]).

snapshot(#{ref := Ref, last_tick := LastTick, entities := Es, rules := RS}) ->
    #{<<"ref">> => snapshot_json:ref(Ref),
      <<"last_tick">> => LastTick,
      <<"entities">> =>
          maps:map(fun(_, #{source := Src, last := Last, last_pos := {E, N},
                            filter := Filter, window := W}) ->
                           #{<<"source">> => Src, <<"last_time_ms">> => Last,
                             <<"last_pos">> => [E, N],
                             <<"filter">> => snapshot_json:filter(Filter),
                             <<"window">> => W}
                   end, Es),
      <<"rules">> =>
          maps:map(fun(_, Subjects) ->
                           maps:map(fun(_, #{count := C, active := A}) ->
                                            #{<<"count">> => C, <<"active">> => A}
                                    end, Subjects)
                   end, RS)}.
