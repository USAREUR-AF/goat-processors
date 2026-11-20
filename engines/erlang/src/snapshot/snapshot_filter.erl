%% Snapshot of the filter (filter.md "Snapshot"): each entity's last
%% position, time, course, speed, stale time and kept time.
-module(snapshot_filter).
-export([snapshot/1]).

snapshot(#{entities := Ents}) ->
    #{<<"entities">> =>
          maps:map(fun(_Key, E) ->
                           maps:from_list([{atom_to_binary(K), V} || {K, V} <- maps:to_list(E)])
                   end, Ents)}.
