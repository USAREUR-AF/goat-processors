%% Snapshot of method assign (correlate-assign.md 0.7 "Snapshot").
-module(snapshot_assign).
-export([snapshot/1]).

snapshot(St) ->
    #{ref := Ref, entities := Ents, reported := Reported, retiring := Retiring, pack := Pack,
      committed := Committed = #{systems := Systems, next := Next}} = St,
    Base = #{<<"ref">> => snapshot_json:ref(Ref),
             <<"entities">> =>
                 maps:from_list(
                   [{K, (snapshot_correlate:entity(E))#{
                          <<"system">> => case assign_membership:system_of(K, Committed) of
                                              none -> null;
                                              S -> trace_assign:system_name(S)
                                          end}}
                    || {K, E} <- maps:to_list(Ents)]),
             <<"systems">> => systems(Systems),
             <<"next_system">> => Next,
             <<"reported">> => lists:sort([K || K <- maps:keys(Reported), maps:is_key(K, Ents)])},
    WithIntervals = snapshot_correlate:intervals(Base, St),
    WithRestart = case maps:is_key(restart, Pack) of
                      false -> WithIntervals;
                      true -> WithIntervals#{<<"restarted">> =>
                                        lists:sort(maps:keys(maps:get(restarted, St)))}
                  end,
    WithBias = case maps:is_key(bias, Pack) of
                   false -> WithRestart;
                   true ->
                       TimeOffset = maps:is_key(time_offset, Pack),
                       WithRestart#{<<"bias">> =>
                                        maps:from_list(
                                          [{<<S/binary, "|", T/binary>>, bias(State, TimeOffset)}
                                           || {{S, T}, State} <- maps:to_list(maps:get(bias, St))])}
               end,
    case maps:get(window, Pack) > 1 of
        false -> WithBias;
        true ->
            WithBias#{<<"retiring">> => lists:sort(maps:keys(Retiring)),
                      <<"histories">> => [history(H) || H <- maps:get(histories, St)]}
    end.

bias(#{oe := OE, we := WE, on := ON, wn := WN, var := Var, n := N, tau := Tau, sums := Sums},
     TimeOffset) ->
    P = #{<<"east">> => OE, <<"weight_east">> => WE,
          <<"north">> => ON, <<"weight_north">> => WN,
          <<"var">> => Var, <<"pairs">> => N},
    case TimeOffset of
        true -> P#{<<"time_offset_ms">> => Tau * 1000, <<"sums">> => tuple_to_list(Sums)};
        false -> P
    end.

history(H) ->
    #{<<"total">> => assign_membership:total(H),
      <<"records">> =>
          [#{<<"cost">> => C, <<"choices">> => Ch, <<"events">> => Evs,
             <<"systems">> => systems(Sys), <<"next_system">> => N}
           || #{cost := C, choices := Ch, events := Evs,
                membership := #{systems := Sys, next := N}} <- H]}.

systems(Systems) ->
    maps:from_list([{trace_assign:system_name(S), Ms} || {S, Ms} <- maps:to_list(Systems)]).
