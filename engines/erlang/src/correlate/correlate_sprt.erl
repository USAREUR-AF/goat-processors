%% The sequential test of method confirm (correlate.md 1.0, Association,
%% "Sequential test"): with the pack's sprt line, Wald's sequential
%% probability ratio test on each pair replaces confirm_count, the hold tests
%% and hold_failures. Each pair holds L, the log-likelihood ratio of "same
%% object" against "different objects", clamped to [lo, up].
-module(correlate_sprt).
-export([bounds/1, reported/2, evidence/2]).

-import(correlate, [entity/2, value/2, pair_view/3]).
-import(correlate_confirm, [pair/2, members/2]).
-import(trace_log, [record/2]).

%% The directive's thresholds, added to its parameters:
%% up = ln((1 - missed) / false), lo = ln(missed / (1 - false)).
bounds(S = #{<<"false">> := False, <<"missed">> := Missed}) ->
    S#{up => math:log((1 - Missed) / False), lo => math:log(Missed / (1 - False))}.

reported(A, St) ->
    case entity(A, St) of
        #{group := none} -> associate(A, St);
        #{group := G} -> in_group(A, G, St)
    end.

%% The gate line's same tests, in pack order.
same_tests(Pack) -> [T || T = {<<"same">>, _} <- maps:get(gate, Pack)].

llr(A, B, St) -> maps:find(pair(A, B), maps:get(llr, St)).

%% A in a group G: only the pair with A's link is updated, the link being the
%% other member whose pair has the greatest L (0 without one), ties to key
%% order. The gate line's same tests run with their records; a failure forces
%% the update. At lo or below, A leaves G (reason release) and every pair
%% naming A at lo or below is removed.
in_group(A, G, St0) ->
    Pack = maps:get(pack, St0),
    #{lo := Lo} = maps:get(sprt, Pack),
    [First | Rest] = [B || B <- members(G, St0), B =/= A],
    Read = fun(B) -> case llr(A, B, St0) of {ok, L} -> L; error -> 0 end end,
    {_, Link} = lists:foldl(fun(B, {LBest, Best}) ->
                                    LB = Read(B),
                                    case LB > LBest of
                                        true -> {LB, B};
                                        false -> {LBest, Best}
                                    end
                            end, {Read(First), First}, Rest),
    {Pass, St1} = correlate_test_kinds:run_tests(same_tests(Pack), <<"gate">>, A, Link, St0),
    {L, St2} = update(A, Link, Pass, St1),
    case L =< Lo of
        false -> St2;
        true ->
            St3 = correlate_confirm:leave(A, G, <<"release">>, St2),
            Llr = maps:filter(fun({X, Y}, LXY) -> not ((X =:= A orelse Y =:= A) andalso LXY =< Lo) end,
                              maps:get(llr, St3)),
            St3#{llr := Llr}
    end.

%% A not in a group: each candidate in key order runs the gate tests, then
%% the confirm tests. All passed: the pair adds A's evidence. A test failed:
%% nothing without an L; with one, the same tests run again without records
%% and the pair adds the evidence, or is forced when one fails. A pair at lo
%% or below is removed; one at up is ready. The ready candidate with the
%% smallest position d² is chosen as in associate; the pair keeps its L.
associate(A, St0) ->
    Pack = maps:get(pack, St0),
    #{up := Up, lo := Lo} = maps:get(sprt, Pack),
    {Ready, St1} =
        lists:foldl(
          fun(B, {Acc, S0}) ->
                  {GatePass, S1} = correlate_test_kinds:run_tests(maps:get(gate, Pack), <<"gate">>,
                                                                  A, B, S0),
                  {AllPass, S2} = case GatePass of
                                      true -> correlate_test_kinds:run_tests(
                                                maps:get(confirm, Pack), <<"confirm">>, A, B, S1);
                                      false -> {false, S1}
                                  end,
                  Updated = case {AllPass, llr(A, B, S2)} of
                                {true, _} -> update(A, B, true, S2);
                                {false, error} -> none;
                                {false, {ok, _}} ->
                                    {SamePass, _} = correlate_test_kinds:run_tests(
                                                      same_tests(Pack), <<"gate">>, A, B, S2),
                                    update(A, B, SamePass, S2)
                            end,
                  case Updated of
                      none -> {Acc, S2};
                      {L, S3} when L =< Lo ->
                          {Acc, S3#{llr := maps:remove(pair(A, B), maps:get(llr, S3))}};
                      {L, S3} when L >= Up -> {[B | Acc], S3};
                      {_, S3} -> {Acc, S3}
                  end
          end, {[], St0}, correlate_confirm:candidates(A, St0)),
    {_, St2} = correlate_confirm:choose(A, lists:reverse(Ready), St1),
    St2.

%% Update of a pair: L = min(max(L + increment, lo), up), from 0 without an
%% L; forced (Pass false): L = lo, increment and d2 null. One sprt record.
update(A, B, Pass, St) ->
    Sprt = #{up := Up, lo := Lo} = maps:get(sprt, maps:get(pack, St)),
    {L, Inc, D2} =
        case Pass of
            true ->
                {I, D} = evidence(pair_view(A, B, St), Sprt),
                L0 = case llr(A, B, St) of {ok, X} -> X; error -> 0 end,
                {min(max(L0 + I, Lo), Up), I, D};
            false -> {Lo, null, null}
        end,
    St1 = St#{llr := (maps:get(llr, St))#{pair(A, B) => L}},
    {L, record(trace_correlate:llr(A, B, L, Up, Lo, Inc, D2), St1)}.

%% One report's evidence for A against B, View = {EA, EB, PredB}:
%% {Increment, D2}. Per axis the terms of the state test; "different
%% objects" adds P = pos_m² to spp and V = vel_ms² to svv. The increment sums
%% 0.5*(q0 - q) + 0.5*ln(det0 / det) over east and north, plus the height
%% term when both last reports have hae; d2 sums q (and dh*dh/h1).
evidence(View = {EA, EB, _}, Sprt) ->
    #{<<"pos_m">> := Pos, <<"vel_ms">> := Vel, <<"hae_sigma_m">> := Hs} = Sprt,
    P = Pos * Pos,
    V = Vel * Vel,
    {East, North} = correlate_test_kinds:state_axes(View),
    {TE, QE} = axis(East, P, V),
    {TN, QN} = axis(North, P, V),
    Inc = TE + TN,
    D2 = QE + QN,
    case {value(<<"hae">>, EA), value(<<"hae">>, EB)} of
        {HA, HB} when is_number(HA), is_number(HB) ->
            H1 = 2 * Hs * Hs,
            H0 = H1 + P,
            Dh = HA - HB,
            {Inc + (0.5 * (Dh * Dh / H0 - Dh * Dh / H1) + 0.5 * math:log(H0 / H1)),
             D2 + Dh * Dh / H1};
        _ -> {Inc, D2}
    end.

axis({Q, {Dp, Dv, Spp, Spv, Svv}, Det}, P, V) ->
    Tpp = Spp + P,
    Tvv = Svv + V,
    Det0 = Tpp * Tvv - Spv * Spv,
    Q0 = (Tvv * Dp * Dp - 2 * Spv * Dp * Dv + Tpp * Dv * Dv) / Det0,
    {0.5 * (Q0 - Q) + 0.5 * math:log(Det0 / Det), Q}.
