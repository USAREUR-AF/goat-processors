%% The filter (spec/filter.md 0.1): the entry point.
%%   load_pack(Dir) -> {ok, Pack} | {error, Why}
%%   new(Pack) -> State
%%   ingest(Report, State) -> {Events, Trace, State}
%%   tick(NowMs, State) -> {Events, Trace, State}
%%   snapshot(State) -> map()
%% "Reports" (the correlator's checks, model_report:validate/1, as filter.md
%% cites correlate.md "Reports"; the out-of-order reject does not apply),
%% "Rules" and "Tick". Conditions are filter_conditions', geometry
%% filter_geometry's. State is a value.
-module(filter).
-behaviour(io_engine).
-export([load_pack/1, new/1, ingest/2, tick/2, snapshot/1]).

load_pack(Dir) -> filter_pack:load_pack(Dir).

%% entities: entity key => #{time_ms, lat, lon, course, speed_ms, stale_ms, kept_ms}
new(Pack) -> #{pack => Pack, entities => #{}}.

snapshot(St) -> snapshot_filter:snapshot(St).

%% ================================================================ ingest

%% Rules: steps 1 (rules in order), 2 (decision), 3 (event), 4 (state).
ingest(Report0, St = #{pack := Pack, entities := Ents}) ->
    case model_report:validate(Report0) of
        {reject, Reason} ->
            %% A rejected report gives no trace and changes no state.
            {[trace_filter:reject(Reason)], [], St};
        {ok, Report} ->
            Key = model_report:entity_key(Report),
            Prior = maps:get(Key, Ents, none),
            Ctx = #{report => Report, key => Key, prior => Prior, entities => Ents},
            {Action, RuleName, Trace} = decide(maps:get(rules, Pack), Ctx, [], Pack),
            NewEnt = update_state(Prior, Report, Action),
            {[trace_filter:decision(Action, Key, RuleName)], Trace,
             St#{entities := Ents#{Key => NewEnt}}}
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
    {Record, Pass} = filter_conditions:evaluate(C, Rule, Ctx),
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
    Ent#{time_ms => maps:get(<<"time_ms">>, Report, null),
         lat => maps:get(<<"lat">>, Report, null),
         lon => maps:get(<<"lon">>, Report, null),
         course => maps:get(<<"course">>, Report, null),
         speed_ms => maps:get(<<"speed_ms">>, Report, null),
         stale_ms => maps:get(<<"stale_ms">>, Report, null)}.

%% On keep, kept_ms becomes the report's time_ms if null or smaller.
keep_time(Ent, _Report, drop) -> Ent;
keep_time(Ent = #{kept_ms := Kept}, Report, keep) ->
    T = maps:get(<<"time_ms">>, Report),
    case Kept =:= null orelse Kept < T of
        true -> Ent#{kept_ms := T};
        false -> Ent
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
                  Rec = trace_filter:age(Key, Age, Forget, Forgotten),
                  case Forgotten of
                      true -> {[trace_filter:forget(Key) | Es], [Rec | Ts], maps:remove(Key, Acc)};
                      false -> {Es, [Rec | Ts], Acc}
                  end
          end, {[], [], Ents}, lists:sort(maps:keys(Ents))),
    {lists:reverse(Events), lists:reverse(Trace), St#{entities := Kept}}.
