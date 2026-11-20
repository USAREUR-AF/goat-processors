%% Sensor bias (correlate-assign.md "Sensor bias"), with its clock offset fit
%% ("Time offset"). The state per pair of sources is
%%   #{{S, T} => #{oe, we, on, wn, var, n, tau, sums}}
%% (pair key "S|T", S < T; tau in seconds and sums {S1..S8} are used only
%% with the pack line time_offset).
-module(assign_bias).
-export([state/2, move/4, update/3]).

-import(correlate, [entity/2]).

%% A pair's state, or the state of a pair with none stored:
%% o = 0, w = 0, var = s², n = 0; with time_offset also tau = 0 and S1..S8 = 0.
state(Pair, St) ->
    #{<<"sigma_m">> := Sigma} = maps:get(bias, maps:get(pack, St)),
    maps:get(Pair, maps:get(bias, St),
             #{oe => 0.0, we => 0.0, on => 0.0, wn => 0.0, var => Sigma * Sigma, n => 0,
               tau => 0.0, sums => {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0}}).

time_offset(St) -> maps:is_key(time_offset, maps:get(pack, St)).

%% Moving B into A's frame: B's prediction Pred (source BSrc) as seen by
%% source ASrc. p + o from pair "BSrc|ASrc" when BSrc is first, p - o from
%% pair "ASrc|BSrc" when ASrc is first; pp + var either way. With
%% time_offset, o - v*tau takes the place of o, v B's predicted velocity on
%% that axis. Never moved without the pack line bias, or between two
%% entities of one source.
move(Pred, ASrc, BSrc, St) ->
    case maps:is_key(bias, maps:get(pack, St)) of
        false -> Pred;
        true when ASrc =:= BSrc -> Pred;
        true ->
            {Pair, Sign} = case BSrc < ASrc of
                               true -> {{BSrc, ASrc}, 1};
                               false -> {{ASrc, BSrc}, -1}
                           end,
            #{oe := OE, on := ON, var := Var, tau := Tau} = state(Pair, St),
            TimeOffset = time_offset(St),
            Shift = fun({P, V, PP, PV, VV}, O0) ->
                            O = case TimeOffset of
                                    true -> O0 - V * Tau;
                                    false -> O0
                                end,
                            Moved = case Sign of
                                        1 -> P + O;
                                        -1 -> P - O
                                    end,
                            {Moved, V, PP + Var, PV, VV}
                    end,
            Pred#{east := Shift(maps:get(east, Pred), OE),
                  north := Shift(maps:get(north, Pred), ON)}
    end.

%% Window step 5, Sensor bias "Update": per committed system track in creation
%% order, its members that are not retiring in key order, each pair X < Y of
%% two different sources with at least one of them among the tick's rows.
update(Now, Rows, St0) ->
    case maps:find(bias, maps:get(pack, St0)) of
        error -> St0;
        {ok, Params} ->
            #{systems := Systems} = maps:get(committed, St0),
            Retiring = maps:get(retiring, St0),
            Pairs = [{X, Y}
                     || S <- lists:sort(maps:keys(Systems)),
                        Ms <- [[M || M <- maps:get(S, Systems), not maps:is_key(M, Retiring)]],
                        X <- Ms, Y <- Ms, X < Y,
                        maps:get(source, entity(X, St0)) =/= maps:get(source, entity(Y, St0)),
                        lists:member(X, Rows) orelse lists:member(Y, Rows)],
            lists:foldl(fun({X, Y}, S) -> pair(X, Y, Now, Params, S) end, St0, Pairs)
    end.

pair(X, Y, Now, #{<<"sigma_m">> := Sigma, <<"floor_m">> := Floor, <<"gate">> := Gate}, St0) ->
    TimeOffset = time_offset(St0),
    %% 1. ES is the entity whose source is first in key order, ET the other;
    %% both predicted to now (not moved).
    [ES, ET] = lists:sort(fun(P, Q) -> maps:get(source, entity(P, St0))
                                           =< maps:get(source, entity(Q, St0)) end, [X, Y]),
    Pair = {maps:get(source, entity(ES, St0)), maps:get(source, entity(ET, St0))},
    PredS = correlate:predict(entity(ES, St0), Now, St0),
    PredT = correlate:predict(entity(ET, St0), Now, St0),
    %% Per axis y = p_ET - p_ES, r = pp_ES + pp_ET; with time_offset also
    %% v = (v_ES + v_ET) / 2.
    Axis = fun(Ax) ->
                   {PS, VS, PPS, _, _} = maps:get(Ax, PredS),
                   {PT, VT, PPT, _, _} = maps:get(Ax, PredT),
                   {PT - PS, PPS + PPT, (VS + VT) / 2}
           end,
    {YE, RE, VE} = Axis(east),
    {YN, RN, VN} = Axis(north),
    State0 = #{oe := OE, we := WE, on := ON, wn := WN, var := Var, n := N, tau := Tau} =
        state(Pair, St0),
    %% 2. d² with the pair's state; with time_offset the expected offset on
    %% each axis is o - v*tau in place of o.
    {XE, XN} = case TimeOffset of
                   true -> {OE - VE * Tau, ON - VN * Tau};
                   false -> {OE, ON}
               end,
    D2 = (YE - XE) * (YE - XE) / (Var + RE) + (YN - XN) * (YN - XN) / (Var + RN),
    %% 3. Accepted when d² < gate: the state is updated and stored.
    Accepted = D2 < Gate,
    {State, St1} =
        case Accepted of
            false -> {State0, St0};
            true ->
                N1 = N + 1,
                Var1 = max(Sigma * Sigma / (N1 + 1), Floor * Floor),
                New = case TimeOffset of
                          false ->
                              WE1 = WE + 1 / RE,
                              WN1 = WN + 1 / RN,
                              State0#{oe := OE + ((1 / RE) / WE1) * (YE - OE), we := WE1,
                                      on := ON + ((1 / RN) / WN1) * (YN - ON), wn := WN1,
                                      var := Var1, n := N1};
                          true ->
                              Fit = time_offset_fit(maps:get(sums, State0), 1 / RE, 1 / RN,
                                                    VE, VN, YE, YN, Sigma, St0),
                              maps:merge(State0#{var := Var1, n := N1}, Fit)
                      end,
                {New, St0#{bias := (maps:get(bias, St0))#{Pair => New}}}
        end,
    %% 4. Trace, with the state after step 3.
    Rec = #{<<"stage">> => <<"bias">>, <<"a">> => X, <<"b">> => Y, <<"test">> => <<"offset">>,
            <<"value">> => D2, <<"limit">> => Gate, <<"pass">> => Accepted,
            <<"east">> => maps:get(oe, State), <<"north">> => maps:get(on, State),
            <<"var">> => maps:get(var, State), <<"pairs">> => maps:get(n, State)},
    trace_log:record(case TimeOffset of
                         true -> Rec#{<<"time_offset_ms">> => maps:get(tau, State) * 1000};
                         false -> Rec
                     end, St1).

%% Sensor bias, "Time offset", an accepted pair: add this pair's terms to the
%% sums S1..S8 (each += one addition of the whole right-hand side), then fit
%% y = o - v*tau by weighted least squares with priors po = 1/s² on o and
%% pt = 1/(t/1000)² on tau, in closed form. Returns the new oe, on, tau, sums
%% and the weight sums we = S1, wn = S2.
time_offset_fit({S1, S2, S3, S4, S5, S6, S7, S8}, We, Wn, Ve, Vn, Ye, Yn, Sigma, St) ->
    #{<<"sigma_ms">> := T} = maps:get(time_offset, maps:get(pack, St)),
    NS1 = S1 + We,
    NS2 = S2 + Wn,
    NS3 = S3 + We * Ve,
    NS4 = S4 + Wn * Vn,
    NS5 = S5 + (We * Ve * Ve + Wn * Vn * Vn),
    NS6 = S6 + We * Ye,
    NS7 = S7 + Wn * Yn,
    NS8 = S8 + (We * Ve * Ye + Wn * Vn * Yn),
    Po = 1 / (Sigma * Sigma),
    Pt = 1 / ((T / 1000) * (T / 1000)),
    A11 = Po + NS1,
    A22 = Po + NS2,
    A13 = -NS3,
    A23 = -NS4,
    A33 = Pt + NS5,
    B1 = NS6,
    B2 = NS7,
    B3 = -NS8,
    Tau = (B3 - A13 * B1 / A11 - A23 * B2 / A22) / (A33 - A13 * A13 / A11 - A23 * A23 / A22),
    #{oe => (B1 - A13 * Tau) / A11, on => (B2 - A23 * Tau) / A22, tau => Tau,
      we => NS1, wn => NS2, sums => {NS1, NS2, NS3, NS4, NS5, NS6, NS7, NS8}}.
