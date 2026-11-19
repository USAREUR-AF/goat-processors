%% The filter engine (spec/filter.md): load_pack, ingest, tick, snapshot.
%% State is a value; ingest and tick return {Events, Trace, NewState}.
%%
%% Report checks are the correlator's own (correlator:validate/1), as filter.md
%% "Reports" cites correlate.md "Reports"; the out-of-order reject does not apply.
-module(filter).
-export([load_pack/1, new/1, ingest/2, tick/2, snapshot/1]).

-define(R, 6371008.8).

load_pack(Dir) -> filter_pack:load_pack(Dir).

%% entities: entity key => #{time_ms, lat, lon, course, speed_ms, stale_ms, kept_ms}
new(Pack) -> #{pack => Pack, entities => #{}}.

%% ================================================================ ingest

%% Rules: steps 1 (rules in order), 2 (decision), 3 (event), 4 (state).
ingest(Report0, St = #{pack := Pack, entities := Ents}) ->
    case correlator:validate(Report0) of
        {reject, Reason} ->
            %% A rejected report gives no trace and changes no state.
            {[#{<<"ev">> => <<"reject">>, <<"reason">> => Reason}], [], St};
        {ok, Report} ->
            Key = correlator:entity_key(Report),
            Prior = maps:get(Key, Ents, none),
            Ctx = #{report => Report, key => Key, prior => Prior, entities => Ents},
            {Action, RuleName, Trace} = decide(maps:get(rules, Pack), Ctx, [], Pack),
            Event = #{<<"ev">> => atom_to_binary(Action), <<"entity">> => Key,
                      <<"rule">> => RuleName},
            NewEnt = update_state(Prior, Report, Action),
            {[Event], Trace, St#{entities := Ents#{Key => NewEnt}}}
    end.

%% Steps 1 and 2: the first rule whose conditions all pass decides; otherwise
%% the pack's default, with rule name "default".
decide([], _Ctx, Trace, #{default := Default}) ->
    {Default, <<"default">>, lists:reverse(Trace)};
decide([#{name := Name, action := Action, conditions := Cs} | Rest], Ctx, Trace0, Pack) ->
    case run_conditions(Cs, Name, Ctx, Trace0) of
        {matched, Trace} -> {Action, Name, lists:reverse(Trace)};
        {no_match, Trace} -> decide(Rest, Ctx, Trace, Pack)
    end.

%% Conditions in pack order; the first that does not pass ends the rule, and
%% the later ones give no record. Trace is accumulated in reverse.
run_conditions([], _Rule, _Ctx, Trace) -> {matched, Trace};
run_conditions([C | Rest], Rule, Ctx, Trace) ->
    {Record, Pass} = evaluate(C, Rule, Ctx),
    case Pass of
        true -> run_conditions(Rest, Rule, Ctx, [Record | Trace]);
        false -> {no_match, [Record | Trace]}
    end.

%% Step 4: state after the decision (filter.md "Rules", "Snapshot").
update_state(none, Report, Action) ->
    keep_time(position(Report, #{kept_ms => null}), Report, Action);
update_state(Ent = #{time_ms := Stored}, Report, Action) ->
    Ent1 = case maps:get(<<"time_ms">>, Report) >= Stored of
               true -> position(Report, Ent);
               false -> Ent           % an older report replaces none of them
           end,
    keep_time(Ent1, Report, Action).

%% time_ms, lat, lon, course, speed_ms, stale_ms from the report; absent is null.
position(Report, Ent) ->
    lists:foldl(fun(K, E) -> E#{binary_to_atom(K) => maps:get(K, Report, null)} end, Ent,
                [<<"time_ms">>, <<"lat">>, <<"lon">>, <<"course">>, <<"speed_ms">>,
                 <<"stale_ms">>]).

%% On keep, kept_ms becomes the report's time_ms if null or smaller.
keep_time(Ent, _Report, drop) -> Ent;
keep_time(Ent = #{kept_ms := Kept}, Report, keep) ->
    T = maps:get(<<"time_ms">>, Report),
    case Kept =:= null orelse Kept < T of
        true -> Ent#{kept_ms := T};
        false -> Ent
    end.

%% ================================================================ conditions

%% One condition: its result (true | false | unknown), with value and limit,
%% then negation. Passes only when the negated result is true.
evaluate(#{test := Test, negated := Negated, params := P}, Rule, Ctx) ->
    {Result, Value, Limit} = condition(Test, P, Ctx),
    Final = case {Result, Negated} of
                {unknown, _} -> unknown;
                {R, false} -> R;
                {R, true} -> not R
            end,
    Pass = Final =:= true,
    Base = #{<<"stage">> => <<"rule">>, <<"rule">> => Rule,
             <<"entity">> => maps:get(key, Ctx), <<"test">> => Test,
             <<"negated">> => Negated, <<"value">> => Value, <<"limit">> => Limit,
             <<"pass">> => Pass},
    Record = case Result of
                 unknown -> Base#{<<"unknown">> => true};
                 _ -> Base
             end,
    {Record, Pass}.

%% Conditions table: {Result, Value, Limit} per condition.
condition(<<"circle">>, #{<<"lat">> := Lat, <<"lon">> := Lon, <<"radius_m">> := Radius},
          #{report := R}) ->
    D = distance(lat(R), lon(R), Lat, Lon),
    {D =< Radius, D, Radius};

condition(<<"polygon">>, #{<<"vertices">> := Vs}, #{report := R}) ->
    Where = polygon(Vs, lat(R), lon(R)),
    {Where =/= outside, atom_to_binary(Where), null};

condition(<<"near">>, P, #{report := R, entities := Ents}) ->
    #{<<"reference">> := Ref, <<"radius_m">> := Radius, <<"max_age_ms">> := MaxAge} = P,
    T = maps:get(<<"time_ms">>, R),
    case maps:get(Ref, Ents, none) of
        none -> {unknown, null, Radius};
        RefEnt ->
            case reference_stale(RefEnt, T, MaxAge) of
                true -> {unknown, null, Radius};
                false ->
                    {PLat, PLon} = predict(RefEnt, T),
                    D = distance(lat(R), lon(R), PLat, PLon),
                    {D =< Radius, D, Radius}
            end
    end;

condition(<<"env">>, #{<<"in">> := List}, #{report := R}) ->
    in_list(environment(R), List);
condition(<<"affiliation">>, #{<<"in">> := List}, #{report := R}) ->
    in_list(affiliation(R), List);
condition(<<"source">>, #{<<"in">> := List}, #{report := R}) ->
    in_list(maps:get(<<"track.source_id">>, R), List);
condition(<<"uid">>, #{<<"in">> := List}, #{report := R}) ->
    in_list(maps:get(<<"uid">>, R), List);

condition(<<"key">>, P = #{<<"name">> := Name}, #{report := R}) ->
    V = maps:get(Name, R, null),
    case P of
        #{<<"eq">> := Text} when V =:= null -> {unknown, null, Text};
        #{<<"eq">> := Text} -> {key_equal(V, Text), V, Text};
        #{<<"in">> := List} when V =:= null -> {unknown, null, List};
        #{<<"in">> := List} -> {lists:any(fun(T) -> key_equal(V, T) end, List), V, List};
        _ -> range(V, P)
    end;

condition(<<"has">>, #{<<"name">> := Name}, #{report := R}) ->
    Present = maps:is_key(Name, R),
    {Present, Present, null};

condition(<<"speed">>, P, #{report := R}) -> range(maps:get(<<"speed_ms">>, R, null), P);
condition(<<"altitude">>, P, #{report := R}) -> range(maps:get(<<"hae">>, R, null), P);

%% interval: time_ms - kept_ms < min_ms; false when there is no kept report.
condition(<<"interval">>, #{<<"min_ms">> := Min}, #{report := R, prior := Prior}) ->
    case kept_ms(Prior) of
        null -> {false, null, Min};
        Kept ->
            V = maps:get(<<"time_ms">>, R) - Kept,
            {V < Min, V, Min}
    end;

%% order: time_ms < kept_ms; false when there is no kept report.
condition(<<"order">>, _P, #{report := R, prior := Prior}) ->
    T = maps:get(<<"time_ms">>, R),
    case kept_ms(Prior) of
        null -> {false, T, null};
        Kept -> {T < Kept, T, Kept}
    end.

lat(R) -> maps:get(<<"lat">>, R).
lon(R) -> maps:get(<<"lon">>, R).

kept_ms(none) -> null;
kept_ms(#{kept_ms := K}) -> K.

%% in lists compare strings byte for byte; unknown when the value is absent.
in_list(null, List) -> {unknown, null, List};
in_list(V, List) -> {lists:member(V, List), V, List}.

%% Ranges: inclusive, an omitted bound is null in limit and no bound; unknown
%% when the value is absent or not a number (true/false are not numbers).
range(V, P) ->
    Min = maps:get(<<"min">>, P, null),
    Max = maps:get(<<"max">>, P, null),
    Limit = [Min, Max],
    case is_number(V) of
        false -> {unknown, V, Limit};
        true -> {(Min =:= null orelse Min =< V) andalso (Max =:= null orelse V =< Max),
                 V, Limit}
    end.

%% key equality between the report's value V and a pack text T.
key_equal(V, T) when is_binary(V) -> V =:= T;
key_equal(V, T) when is_number(V) ->
    case filter_pack:read_number(T) of
        not_a_number -> false;
        F -> F == V
    end;
key_equal(true, T) -> T =:= <<"true">>;
key_equal(false, T) -> T =:= <<"false">>;
key_equal(_ArrayOrObject, _T) -> false.

%% Reports: environment is the third "-"-separated element of type.
environment(R) ->
    case type_elements(R) of
        [_, _, Env | _] -> Env;
        _ -> null
    end.

%% Reports: affiliation is the second element when the first is exactly "a".
affiliation(R) ->
    case type_elements(R) of
        [<<"a">>, Aff | _] -> Aff;
        _ -> null
    end.

type_elements(R) ->
    case maps:get(<<"type">>, R, null) of
        null -> [];
        Type -> binary:split(Type, <<"-">>, [global])
    end.

%% near: stale when abs(time_ms - ref.time_ms) > max_age_ms, or when ref.stale_ms
%% is present and time_ms >= ref.stale_ms.
reference_stale(#{time_ms := RefT, stale_ms := RefStale}, T, MaxAge) ->
    abs(T - RefT) > MaxAge orelse (RefStale =/= null andalso T >= RefStale).

%% ================================================================ geometry

rad(X) -> X * math:pi() / 180.
deg(X) -> X * 180 / math:pi().

%% wrap(x): add or subtract 360 until x is in (-180, 180].
wrap(X) when X > 180 -> wrap(X - 360);
wrap(X) when X =< -180 -> wrap(X + 360);
wrap(X) -> X.

%% Distance (haversine), steps 1 to 4; point 1 is the report.
distance(Lat1, Lon1, Lat2, Lon2) ->
    P1 = rad(Lat1),
    P2 = rad(Lat2),
    Dp = rad(Lat2 - Lat1),
    Dl = rad(wrap(Lon2 - Lon1)),
    S1 = math:sin(Dp / 2),
    S2 = math:sin(Dl / 2),
    H = S1 * S1 + ((math:cos(P1) * math:cos(P2)) * S2) * S2,
    (2 * ?R) * math:asin(min(1, math:sqrt(H))).

%% Reference prediction to time T, steps 1 to 3.
predict(#{time_ms := T0, lat := Lat, lon := Lon, course := Course, speed_ms := Speed}, T) ->
    Dt = (T - T0) / 1000,
    {Dn, De} = case Course =/= null andalso Speed =/= null of
                   true -> {Speed * math:cos(rad(Course)) * Dt,
                            Speed * math:sin(rad(Course)) * Dt};
                   false -> {0, 0}
               end,
    {Lat + deg(Dn / ?R), wrap(Lon + deg(De / (?R * math:cos(rad(Lat)))))}.

%% Polygon: unwrap longitudes about the first vertex, then the boundary step,
%% then crossings (even-odd). Returns boundary | inside | outside.
polygon(Vertices = [{_, Lon0} | _], Lat, Lon) ->
    Points = [{Lon0 + wrap(VLon - Lon0), VLat} || {VLat, VLon} <- Vertices],
    Px = Lon0 + wrap(Lon - Lon0),
    Py = Lat,
    Edges = lists:zip(Points, tl(Points) ++ [hd(Points)]),
    case lists:any(fun(E) -> on_edge(E, Px, Py) end, Edges) of
        true -> boundary;
        false ->
            case lists:foldl(fun(E, In) -> crosses(E, Px, Py) xor In end, false, Edges) of
                true -> inside;
                false -> outside
            end
    end.

%% Boundary: c == 0 exactly and the point within the edge's bounding box.
on_edge({{Xi, Yi}, {Xj, Yj}}, Px, Py) ->
    C = (Xj - Xi) * (Py - Yi) - (Yj - Yi) * (Px - Xi),
    C == 0 andalso min(Xi, Xj) =< Px andalso Px =< max(Xi, Xj)
        andalso min(Yi, Yj) =< Py andalso Py =< max(Yi, Yj).

%% Crossings: the edge straddles py and the crossing is right of px.
crosses({{Xi, Yi}, {Xj, Yj}}, Px, Py) ->
    case (Yi > Py) =/= (Yj > Py) of
        true -> Px < (Xj - Xi) * (Py - Yi) / (Yj - Yi) + Xi;
        false -> false
    end.

%% ================================================================ tick

%% Tick: entities in key order; each gives an age record; forgotten when
%% now_ms - time_ms > forget_ms.
tick(Now, St = #{pack := #{forget_ms := Forget}, entities := Ents}) ->
    {Events, Trace, Kept} =
        lists:foldl(
          fun(Key, {Es, Ts, Acc}) ->
                  Age = Now - maps:get(time_ms, maps:get(Key, Ents)),
                  Forgotten = Age > Forget,
                  Rec = #{<<"stage">> => <<"forget">>, <<"entity">> => Key,
                          <<"test">> => <<"age">>, <<"value">> => Age,
                          <<"limit">> => Forget, <<"pass">> => Forgotten},
                  case Forgotten of
                      true -> {[#{<<"ev">> => <<"forget">>, <<"entity">> => Key} | Es],
                               [Rec | Ts], maps:remove(Key, Acc)};
                      false -> {Es, [Rec | Ts], Acc}
                  end
          end, {[], [], Ents}, lists:sort(maps:keys(Ents))),
    {lists:reverse(Events), lists:reverse(Trace), St#{entities := Kept}}.

%% ================================================================ snapshot

snapshot(#{entities := Ents}) ->
    #{<<"entities">> =>
          maps:map(fun(_Key, E) ->
                           maps:from_list([{atom_to_binary(K), V} || {K, V} <- maps:to_list(E)])
                   end, Ents)}.
