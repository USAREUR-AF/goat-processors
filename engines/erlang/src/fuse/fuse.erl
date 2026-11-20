%% Fuse (spec/fuse.md 0.2): the entry point.
%%   load_pack(Dir) -> {ok, Pack} | {error, Why}
%%   new(Pack) -> State
%%   ingest(Report, State) -> {Events, Trace, State}
%%   tick(NowMs, State) -> {Events, Trace, State}
%%   snapshot(State) -> map()
%% "Reports", "Groups", "On each tick" and the "Fused event"; the
%% kinematics methods are fuse_kinematics', the attribute rules
%% fuse_attributes'. Frame and filter are correlate.md's (model_frame,
%% model_kalman). State is a value; an entity is #{time, group, filter,
%% report}: last_time_ms, the group name (a binary, or null for its own
%% unnamed group), the filter and the last normalized report.
-module(fuse).
-behaviour(io_engine).
-export([load_pack/1, new/1, ingest/2, tick/2, snapshot/1]).
-export([rank/2, rank_or_null/2, first_best/2]).

load_pack(Dir) -> fuse_pack:load_pack(Dir).

new(Pack) -> #{pack => Pack, ref => none, entities => #{}}.

snapshot(St) -> snapshot_fuse:snapshot(St).

%% ================================================================ Reports

%% correlate.md "Reports": optional keys, absent when of the wrong type (a
%% ce of 0 or below is absent); fuse.md "Reports": fuse.group, absent unless
%% a non-empty string.
optional() -> model_report:optional() ++ [{<<"fuse.group">>, nonempty_string}].

%% fuse.md "Reports": reject a missing required key; ignore a stale report;
%% otherwise accept the normalized report.
ingest(Report, St) ->
    case model_report:first_missing(Report) of
        none ->
            R = model_report:normalize(Report, optional()),
            Key = model_report:entity_key(R),
            T = maps:get(<<"time_ms">>, R),
            case maps:find(Key, maps:get(entities, St)) of
                {ok, #{time := Last}} when T < Last ->
                    {[trace_fuse:stale_report(Key, T, Last)], [], St};
                _ ->
                    accept(Key, R, St)
            end;
        Missing ->
            {[trace_fuse:reject(model_report:missing_reason(Missing))], [], St}
    end.

%% Accept: frame reference, filter update (correlate.md "Track estimate"),
%% then the group (fuse.md "Groups"): new, move, or nothing.
accept(Key, R, St0) ->
    #{pack := Pack, entities := Ents} = St0,
    F = maps:get(filter, Pack),
    T = maps:get(<<"time_ms">>, R),
    Ref = case maps:get(ref, St0) of
              none -> {maps:get(<<"lat">>, R), maps:get(<<"lon">>, R)};
              Ref0 -> Ref0
          end,
    Z = model_frame:to_plane(Ref, maps:get(<<"lat">>, R), maps:get(<<"lon">>, R)),
    Ce = maps:get(<<"ce">>, R, maps:get(<<"default_ce_m">>, F)),
    Vel = model_frame:velocity(maps:get(<<"course">>, R, null), maps:get(<<"speed_ms">>, R, null)),
    Group = maps:get(<<"fuse.group">>, R, null),
    {Filter, Events} =
        case maps:find(Key, Ents) of
            error ->
                {model_kalman:init(Z, Vel, Ce, F), [trace_fuse:new(Key, Group)]};
            {ok, #{time := Last, filter := Old, group := OldGroup}} ->
                {Updated, _} = model_kalman:update(Old, (T - Last) / 1000,
                                                   maps:get(<<"accel_var">>, F), Z, Vel, Ce, F),
                {Updated,
                 case OldGroup =:= Group of
                     true -> [];
                     false -> [trace_fuse:move(Key, OldGroup, Group)]
                 end}
        end,
    Ent = #{time => T, group => Group, filter => Filter, report => R},
    {Events, [], St0#{ref := Ref, entities := Ents#{Key => Ent}}}.

%% ================================================================ Tick

%% fuse.md "On each tick": 1. staleness, 2. fused output per group.
tick(Now, St0) ->
    {Drops, St1} = staleness(Now, St0),
    {Fused, Trace} = fused_output(Now, St1),
    {Drops ++ Fused, Trace, St1}.

%% Step 1, staleness, entities in key order.
staleness(Now, St = #{pack := Pack, entities := Ents}) ->
    Stale = [K || K <- lists:sort(maps:keys(Ents)),
                  is_stale(maps:get(K, Ents), Now, maps:get(stale_ms, Pack))],
    Drops = [trace_fuse:drop(K, maps:get(group, maps:get(K, Ents))) || K <- Stale],
    {Drops, St#{entities := maps:without(Stale, Ents)}}.

is_stale(#{time := Last, report := R}, Now, PackStale) ->
    Now - Last > PackStale orelse
        case maps:find(<<"stale_ms">>, R) of
            {ok, S} -> Now >= S;
            error -> false
        end.

%% fuse.md "Groups", output order: named groups in byte order of name, then
%% unnamed groups in key order of their one member. Members in key order.
groups(Ents) ->
    Keyed = lists:sort([{K, maps:get(group, E)} || K := E <- Ents]),
    Names = lists:usort([G || {_, G} <- Keyed, G =/= null]),
    [{G, [K || {K, GK} <- Keyed, GK =:= G]} || G <- Names] ++
        [{null, [K]} || {K, null} <- Keyed].

%% Step 2, fused output.
fused_output(Now, St) ->
    Results = [fuse_group(G, Ms, Now, St) || {G, Ms} <- groups(maps:get(entities, St))],
    {[Ev || {Ev, _} <- Results], lists:append([Tr || {_, Tr} <- Results])}.

%% One group: 2.1 predict, 2.2 combine, 2.3 attributes, 2.4 the fused event.
fuse_group(G, Ms, Now, St = #{pack := Pack, entities := Ents}) ->
    Q = maps:get(<<"accel_var">>, maps:get(filter, Pack)),
    Method = maps:get(kinematics, Pack),
    %% Members as {Key, Entity, Predicted}, in key order.
    Members = [begin
                   E = maps:get(K, Ents),
                   {K, E, model_kalman:predict(maps:get(filter, E),
                                               (Now - maps:get(time, E)) / 1000, Q)}
               end || K <- Ms],
    {{East, North}, From, Folds} = fuse_kinematics:combine(Method, Members, Pack),
    KinTrace = trace_fuse:kinematics(
                 G, Method,
                 [trace_fuse:candidate(K, fuse_kinematics:var(P), maps:get(time, E),
                                       rank_or_null(E, Pack))
                  || {K, E, P} <- Members],
                 From),
    {Attributes, AttrTrace} = fuse_attributes:attributes(G, Members, Pack),
    Height = fuse_kinematics:height(Method, From, Members),
    Ev = fused_event(G, Ms, From, East, North, Height, Attributes, St),
    {Ev, [trace_fuse:intersect(G, Y, W) || {Y, W} <- Folds] ++ [KinTrace | AttrTrace]}.

%% fuse.md "Fused event".
fused_event(G, Ms, From, {PE, VE, PPE, _}, {PN, VN, PPN, _}, Height, Attributes, St) ->
    {Lat, Lon} = model_frame:from_plane(maps:get(ref, St), PE, PN),
    Ev = #{<<"ev">> => <<"fused">>, <<"group">> => G, <<"members">> => Ms,
           <<"from">> => From, <<"lat">> => Lat, <<"lon">> => Lon,
           <<"course">> => model_frame:course(VE, VN),
           <<"speed_ms">> => math:sqrt(VE * VE + VN * VN),
           <<"ce">> => math:sqrt((PPE + PPN) / 2), <<"attributes">> => Attributes},
    case Height of
        none -> Ev;
        {Hae, HaeFrom} -> Ev#{<<"hae">> => Hae, <<"hae_from">> => HaeFrom}
    end.

%% Rank: index of the source among the pack's source lines; unlisted ranks
%% after every listed source (for comparison) and is null in the trace.
rank(E, #{sources := Ss}) ->
    Src = maps:get(<<"track.source_id">>, maps:get(report, E)),
    index(Src, Ss, 0).

index(_, [], I) -> I;
index(X, [X | _], I) -> I;
index(X, [_ | Rest], I) -> index(X, Rest, I + 1).

rank_or_null(E, Pack = #{sources := Ss}) ->
    case rank(E, Pack) of
        R when R =:= length(Ss) -> null;
        R -> R
    end.

%% The first element with the smallest score (ties to list order), or none.
first_best([], _Score) -> none;
first_best([X | Xs], Score) ->
    {_, Best} = lists:foldl(fun(Y, {S, B}) ->
                                    SY = Score(Y),
                                    if SY < S -> {SY, Y}; true -> {S, B} end
                            end, {Score(X), X}, Xs),
    Best.
