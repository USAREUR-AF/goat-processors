%% Rules and forwarding (quality.md "Rules", "Forwarding"): evaluating each
%% rule for a subject, its state {count, active}, its action events, ending
%% a subject's rules when it is forgotten, and the pass event.
-module(quality_rules).
-export([new/1, evaluate/4, step/4, forget_subject/3, pass/5]).

-import(trace_log, [emit/2, record/2]).

%% The rule states: #{RuleName => #{Subject => #{count, active}}}.
new(Pack) -> maps:from_list([{maps:get(name, R), #{}} || R <- maps:get(rules, Pack)]).

active(#{name := Name}, Subject, #{rules := Rules}) ->
    case maps:get(Subject, maps:get(Name, Rules), none) of
        #{active := true} -> true;
        _ -> false
    end.

%% Evaluate each rule of the scope, in pack order, for one subject.
evaluate(Scope, Subject, Ms, St0) ->
    Rules = [R || R = #{scope := S} <- maps:get(rules, maps:get(pack, St0)), S =:= Scope],
    lists:foldl(fun(R, St) -> evaluate_rule(R, Subject, maps:get(maps:get(measure, R), Ms), St)
                end, St0, Rules).

%% Rules, evaluation, for one subject: the rule's state for it, the step,
%% the event if any and the trace record.
evaluate_rule(Rule = #{name := Name}, Subject, V, St0) ->
    #{rules := RS} = St0,
    State0 = maps:get(Subject, maps:get(Name, RS), #{count => 0, active => false}),
    {TraceLimit, Pass, State, Event} = step(Rule, Subject, State0, V),
    St1 = St0#{rules := RS#{Name := (maps:get(Name, RS))#{Subject => State}}},
    St2 = case Event of none -> St1; _ -> emit(Event, St1) end,
    record(trace_quality:rule(Name, Subject, maps:get(measure, Rule), V, TraceLimit, Pass,
                              State),
           St2).

%% One rule's step for a measure value V from its state {count, active}
%% (created {0, false}): {TraceLimit, Pass, State, Event | none}. Pure.
step(Rule, Subject, #{count := Count0, active := Active0}, V) ->
    #{op := Op, limit := Limit, clear := Clear, for := For} = Rule,
    case Active0 of
        false ->
            Met = V =/= null andalso holds(Op, V, Limit),
            Count = case Met of true -> Count0 + 1; false -> 0 end,
            case Count >= For of
                true -> {Limit, Met, #{count => 0, active => true},
                         trace_quality:action_start(Rule, Subject, V)};
                false -> {Limit, Met, #{count => Count, active => false}, none}
            end;
        true ->
            Cleared = V =/= null andalso clears(Op, V, Clear),
            case Cleared of
                true -> {Clear, true, #{count => 0, active => false},
                         trace_quality:action_end(Rule, Subject, <<"clear">>, V)};
                false -> {Clear, false, #{count => Count0, active => true}, none}
            end
    end.

%% Erlang compares an integer with a float by value, so an integer measure
%% equal to the limit is compared exactly.
holds(<<"<">>, V, L) -> V < L;
holds(<<"<=">>, V, L) -> V =< L;
holds(<<">">>, V, L) -> V > L;
holds(<<">=">>, V, L) -> V >= L.

clears(<<">", _/binary>>, V, C) -> V < C;
clears(<<"<", _/binary>>, V, C) -> V > C.

%% Each active rule of the scope for the subject ends (reason forget, value
%% null), in pack order; every rule state for the subject is removed.
forget_subject(Scope, Subject, St0) ->
    Rules = [R || R = #{scope := S} <- maps:get(rules, maps:get(pack, St0)), S =:= Scope],
    lists:foldl(
      fun(R = #{name := Name}, St) ->
              St1 = case active(R, Subject, St) of
                        true -> emit(trace_quality:action_end(R, Subject, <<"forget">>, null), St);
                        false -> St
                    end,
              #{rules := RS} = St1,
              St1#{rules := RS#{Name := maps:remove(Subject, maps:get(Name, RS))}}
      end, St0, Rules).

%% ---------------------------------------------------------------- forwarding

%% Forwarding: the actions in force other than alert, in pack order. Source
%% rules are those of the report's own track.source_id (quality.md "Reports"),
%% which differs from the entity's source only when keys collide.
pass(Key, Src, Report, Ce, St = #{pack := Pack}) ->
    InForce = [R || R = #{action := A} <- maps:get(rules, Pack), A =/= <<"alert">>,
                    active(R, subject(R, Key, Src), St)],
    Names = [maps:get(name, R) || R <- InForce],
    case [R || R = #{action := <<"drop">>} <- InForce] of
        [_ | _] -> trace_quality:pass(Key, Names, withheld);
        [] -> trace_quality:pass(Key, Names, marks(InForce, downgrade(InForce, Ce, Pack, Report)))
    end.

subject(#{scope := entity}, Key, _Src) -> Key;
subject(#{scope := source}, _Key, Src) -> Src.

%% ce: the valid ce or default_ce_m, times each downgrade factor in pack
%% order; the largest finite binary64 when that overflows to infinity.
downgrade(InForce, Ce, Pack, Report) ->
    case [Fa || #{action := <<"downgrade">>, factor := Fa} <- InForce] of
        [] -> Report;
        Factors ->
            X0 = case Ce of null -> maps:get(<<"default_ce_m">>, maps:get(filter, Pack));
                     _ -> Ce
                 end,
            Report#{<<"ce">> => multiply(X0, Factors)}
    end.

%% OTP raises badarith where IEEE-754 gives infinity; every factor is at least
%% 1, so once infinite x stays infinite, and the result is the largest finite
%% binary64.
multiply(X0, Factors) ->
    try lists:foldl(fun(Fa, X) -> X * Fa end, X0, Factors)
    catch error:badarith -> 1.7976931348623157e308
    end.

%% quality.marks: the received list when it is all strings, else empty; then
%% each mark rule name in pack order that it does not hold.
marks(InForce, Report) ->
    case [Name || #{action := <<"mark">>, name := Name} <- InForce] of
        [] -> Report;
        Names ->
            Start = case maps:get(<<"quality.marks">>, Report, null) of
                        L when is_list(L) ->
                            case lists:all(fun is_binary/1, L) of
                                true -> L;
                                false -> []
                            end;
                        _ -> []
                    end,
            Marks = lists:foldl(fun(Nm, Acc) ->
                                        case lists:member(Nm, Acc) of
                                            true -> Acc;
                                            false -> Acc ++ [Nm]
                                        end
                                end, Start, Names),
            Report#{<<"quality.marks">> => Marks}
    end.
