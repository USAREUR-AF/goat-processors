%% Snapshot values every function shares (spec/vector-format.md, each
%% spec's "Snapshot"): the reference point and a filter. Pure.
-module(snapshot_json).
-export([ref/1, filter/1, axis/1]).

%% The frame's reference [lat, lon], or null before the first report.
ref(none) -> null;
ref(null) -> null;
ref({Lat, Lon}) -> [Lat, Lon].

%% A filter #{east, north} as {"east": [p, v, pp, pv, vv], "north": [...]}.
filter(#{east := East, north := North}) ->
    #{<<"east">> => axis(East), <<"north">> => axis(North)}.

axis(Axis) -> tuple_to_list(Axis).
