%% Sensor bias (correlate-assign.md "Sensor bias"), with its clock offset fit
%% ("Time offset"). The state per pair of sources is
%%   #{{S, T} => #{oe, we, on, wn, var, n, tau, sums}}
%% (pair key "S|T", S < T; tau in seconds and sums {S1..S8} are used only
%% with the pack line time_offset). The math is pure: move/4 and observe/5
%% take the pack's lines and a pair's state, never the engine state.
-module(assign_bias).
-export([context/1, move/4, update/3, observe/5, initial/1, time_offset_fit/7]).

-import(correlate, [entity/2]).

%% What moving needs from the engine state: none without the pack line
%% bias, else {Pairs, Sigma, TimeOffset}.
context(#{pack := Pack, bias := Pairs}) ->
    case Pack of
        #{bias := #{<<"sigma_m">> := Sigma}} -> {Pairs, Sigma, maps:is_key(time_offset, Pack)};
        _ -> none
    end.

%% A pair's state with none stored: o = 0, w = 0, var = s², n = 0; with
%% time_offset also tau = 0 and S1..S8 = 0.
initial(Sigma) ->
    #{oe => 0.0, we => 0.0, on => 0.0, wn => 0.0, var => Sigma * Sigma, n => 0,
      tau => 0.0, sums => {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0}}.

state(Pair, Pairs, Sigma) ->
    case Pairs of
        #{Pair := State} -> State;
        _ -> initial(Sigma)
    end.

%% Moving B into A's frame: B's prediction Pred (source BSrc) as seen by
%% source ASrc. p + o from pair "BSrc|ASrc" when BSrc is first, p - o from
%% pair "ASrc|BSrc" when ASrc is first; pp + var either way. With
%% time_offset, o - v*tau takes the place of o, v B's predicted velocity on
%% that axis. Never moved without the pack line bias (context none), or
%% between two entities of one source. Pure.
move(Pred, _ASrc, _BSrc, none) -> Pred;
move(Pred, Src, Src, _Context) -> Pred;
move(Pred, ASrc, BSrc, {Pairs, Sigma, TimeOffset}) ->
    {Pair, Sign} = case BSrc < ASrc of
                       true -> {{BSrc, ASrc}, 1};
                       false -> {{ASrc, BSrc}, -1}
                   end,
    #{oe := OE, on := ON, var := Var, tau := Tau} = state(Pair, Pairs, Sigma),
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
          north := Shift(maps:get(north, Pred), ON)}.

%% Window step 5, Sensor bias "Update": per committed system track in creation
%% order, its members that are not retiring in key order, each pair X < Y of
%% two different sources with at least one of them among the tick's rows.
update(Now, Rows, St0) ->
    case maps:find(bias, maps:get(pack, St0)) of
        error -> St0;
        {ok, _} ->
            #{systems := Systems} = maps:get(committed, St0),
            Retiring = maps:get(retiring, St0),
            Source = fun(K) -> maps:get(source, entity(K, St0)) end,
            Pairs = [{X, Y}
                     || S <- lists:sort(maps:keys(Systems)),
                        Ms <- [[M || M <- maps:get(S, Systems), not maps:is_key(M, Retiring)]],
                        X <- Ms, Y <- Ms, X < Y,
                        Source(X) =/= Source(Y),
                        lists:member(X, Rows) orelse lists:member(Y, Rows)],
            lists:foldl(fun({X, Y}, S) -> pair(X, Y, Now, S) end, St0, Pairs)
    end.

%% One pair of entities: step 1, ES the entity whose source is first in key
%% order, ET the other, both predicted to now (not moved); steps 2 and 3 by
%% observe/5; step 4, the trace record with the state after step 3.
pair(X, Y, Now, St0 = #{pack := Pack, bias := Pairs}) ->
    #{bias := Params = #{<<"sigma_m">> := Sigma, <<"gate">> := Gate}} = Pack,
    TimeOffset = maps:get(time_offset, Pack, none),
    [ES, ET] = lists:sort(fun(P, Q) -> maps:get(source, entity(P, St0))
                                           =< maps:get(source, entity(Q, St0)) end, [X, Y]),
    Pair = {maps:get(source, entity(ES, St0)), maps:get(source, entity(ET, St0))},
    PredS = correlate:predict(entity(ES, St0), Now, Pack),
    PredT = correlate:predict(entity(ET, St0), Now, Pack),
    {D2, Accepted, State} = observe(state(Pair, Pairs, Sigma), PredS, PredT, Params, TimeOffset),
    St1 = case Accepted of
              true -> St0#{bias := Pairs#{Pair => State}};
              false -> St0
          end,
    trace_log:record(trace_assign:bias(X, Y, D2, Gate, Accepted, State, TimeOffset =/= none), St1).

%% Steps 2 and 3 for one pair's state and the two predictions: per axis
%% y = p_ET - p_ES, r = pp_ES + pp_ET (with time_offset also
%% v = (v_ES + v_ET) / 2); d² with the pair's state, the expected offset on
%% each axis being o - v*tau in place of o with time_offset; accepted when
%% d² < gate, and then the state updated. Returns {D2, Accepted, State}.
%% TimeOffset is the time_offset line's parameters, or none. Pure.
observe(State0, PredS, PredT, #{<<"sigma_m">> := Sigma, <<"floor_m">> := Floor,
                                <<"gate">> := Gate}, TimeOffset) ->
    Axis = fun(Ax) ->
                   {PS, VS, PPS, _, _} = maps:get(Ax, PredS),
                   {PT, VT, PPT, _, _} = maps:get(Ax, PredT),
                   {PT - PS, PPS + PPT, (VS + VT) / 2}
           end,
    {YE, RE, VE} = Axis(east),
    {YN, RN, VN} = Axis(north),
    #{oe := OE, we := WE, on := ON, wn := WN, var := Var, n := N, tau := Tau} = State0,
    {XE, XN} = case TimeOffset of
                   none -> {OE, ON};
                   _ -> {OE - VE * Tau, ON - VN * Tau}
               end,
    D2 = (YE - XE) * (YE - XE) / (Var + RE) + (YN - XN) * (YN - XN) / (Var + RN),
    Accepted = D2 < Gate,
    State = case Accepted of
                false -> State0;
                true ->
                    N1 = N + 1,
                    Var1 = max(Sigma * Sigma / (N1 + 1), Floor * Floor),
                    case TimeOffset of
                        none ->
                            WE1 = WE + 1 / RE,
                            WN1 = WN + 1 / RN,
                            State0#{oe := OE + ((1 / RE) / WE1) * (YE - OE), we := WE1,
                                    on := ON + ((1 / RN) / WN1) * (YN - ON), wn := WN1,
                                    var := Var1, n := N1};
                        #{<<"sigma_ms">> := T} ->
                            Fit = time_offset_fit(maps:get(sums, State0), 1 / RE, 1 / RN,
                                                  {VE, VN}, {YE, YN}, Sigma, T),
                            maps:merge(State0#{var := Var1, n := N1}, Fit)
                    end
            end,
    {D2, Accepted, State}.

%% Sensor bias, "Time offset", an accepted pair: add this pair's terms to the
%% sums S1..S8 (each += one addition of the whole right-hand side), then fit
%% y = o - v*tau by weighted least squares with priors po = 1/s² on o and
%% pt = 1/(t/1000)² on tau, in closed form. Returns the new oe, on, tau, sums
%% and the weight sums we = S1, wn = S2. Pure.
time_offset_fit({S1, S2, S3, S4, S5, S6, S7, S8}, We, Wn, {Ve, Vn}, {Ye, Yn}, Sigma, T) ->
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
