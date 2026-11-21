%% Snapshot of the correlator (correlate.md 1.0 "Snapshot"): an entity's time and
%% estimate, shared with method assign, and the confirm method's state.
-module(snapshot_correlate).
-export([entity/1, confirm/1, intervals/2]).

%% An entity's time and estimate: filter, plus models and mode with two
%% models, plus time (its timing variance) when its last report had a time
%% error above 0.
entity(E) ->
    Base0 = #{<<"last_time_ms">> => maps:get(time, E),
              <<"filter">> => snapshot_json:filter(maps:get(filter, E))},
    Base = case E of
               #{time_error := Te, timing := {VarE, VarN}} when Te > 0 ->
                   Base0#{<<"time">> => #{<<"var_east">> => VarE, <<"var_north">> => VarN}};
               _ -> Base0
           end,
    case E of
        #{models := {Quiet, Maneuver}, mode := {Mu1, Mu2}} ->
            Base#{<<"models">> => #{<<"quiet">> => snapshot_json:filter(Quiet),
                                    <<"maneuver">> => snapshot_json:filter(Maneuver)},
                  <<"mode">> => [Mu1, Mu2]};
        _ -> Base
    end.

%% With stale_rate, intervals: each source with at least one interval, its
%% list oldest first. Shared with method assign.
intervals(Snap, #{pack := #{stale_rate := _}, intervals := Is}) ->
    Snap#{<<"intervals">> => Is};
intervals(Snap, _St) -> Snap.

%% The confirm method: entities with group and hold failures, groups, pair
%% counts ("a|b") and the next group number; with sprt, llr ("a|b" => L);
%% with stale_rate, intervals.
confirm(St = #{pack := Pack, llr := Llr}) ->
    Snap = confirm_base(St),
    WithLlr = case maps:is_key(sprt, Pack) of
                  true -> Snap#{<<"llr">> => pairs(Llr)};
                  false -> Snap
              end,
    intervals(WithLlr, St).

pairs(M) -> maps:from_list([{<<A/binary, "|", B/binary>>, N} || {{A, B}, N} <- maps:to_list(M)]).

confirm_base(St) ->
    #{ref := Ref, entities := Ents, groups := Groups, counts := Counts,
      next_group := Next} = St,
    #{<<"ref">> => snapshot_json:ref(Ref),
      <<"entities">> =>
          maps:from_list(
            [{K, (entity(E))#{<<"group">> => case maps:get(group, E) of
                                                 none -> null;
                                                 G -> trace_correlate:group_name(G)
                                             end,
                              <<"hold_failures">> => maps:get(hold_failures, E)}}
             || {K, E} <- maps:to_list(Ents)]),
      <<"groups">> => maps:from_list([{trace_correlate:group_name(G), Ms}
                                      || {G, Ms} <- maps:to_list(Groups)]),
      <<"counts">> => pairs(Counts),
      <<"next_group">> => Next}.
