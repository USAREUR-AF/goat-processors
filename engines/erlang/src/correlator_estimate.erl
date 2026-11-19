%% An entity's estimate: one filter (correlate.md "Track estimate"), or two
%% models combined (correlate.md "Two-model filter") when the pack has a
%% maneuver line. The estimate lives in the entity map under `filter`, plus
%% `models` => {Quiet, Maneuver} and `mode` => {Mu1, Mu2} with two models.
-module(correlator_estimate).
-export([init/4, update/6, predict/3]).

%% First report. Two models: both are the first-report filter, mu1 = b / s,
%% mu2 = a / s, and the combination is that same filter.
init(Z, Vel, Ce, Pack) ->
    F = maps:get(filter, Pack),
    Filter = correlator_filter:init(Z, Vel, Ce, F),
    case maps:find(maneuver, Pack) of
        error -> #{filter => Filter};
        {ok, M} ->
            #{<<"p_enter">> := A, <<"p_leave">> := B} = M,
            S = A + B,
            #{filter => Filter, models => {Filter, Filter}, mode => {B / S, A / S}}
    end.

%% Later report Dt seconds after the last. Returns {Estimate, Records}, the
%% records being [{Test, Model, Value}] for the trace (none with one model).
update(Est, Dt, Z, Vel, Ce, Pack) ->
    F = maps:get(filter, Pack),
    Q1 = maps:get(<<"accel_var">>, F),
    case maps:find(maneuver, Pack) of
        error ->
            {Filter, _} = correlator_filter:update(maps:get(filter, Est), Dt, Q1, Z, Vel, Ce, F),
            {#{filter => Filter}, []};
        {ok, M} ->
            #{<<"accel_var">> := Q2, <<"p_enter">> := A, <<"p_leave">> := B} = M,
            {Model1, Model2} = maps:get(models, Est),
            {Mu1, Mu2} = maps:get(mode, Est),
            {T11, T12, T21, T22} = switching(A, B, Dt),
            %% Step 1, mixing.
            C1 = T11 * Mu1 + T21 * Mu2,
            C2 = T12 * Mu1 + T22 * Mu2,
            Mixed1 = mix(C1, T11 * Mu1, T21 * Mu2, Model1, Model2, Model1),
            Mixed2 = mix(C2, T12 * Mu1, T22 * Mu2, Model1, Model2, Model2),
            %% Step 2, predict and update; step 3, likelihood.
            {New1, Terms1} = correlator_filter:update(Mixed1, Dt, Q1, Z, Vel, Ce, F),
            {New2, Terms2} = correlator_filter:update(Mixed2, Dt, Q2, Z, Vel, Ce, F),
            L1 = likelihood(Terms1),
            L2 = likelihood(Terms2),
            %% Step 4, mode probabilities.
            {NewMu1, NewMu2} = mode(C1, C2, L1, L2),
            %% Step 5, combination.
            {#{filter => blend(NewMu1, NewMu2, New1, New2),
               models => {New1, New2}, mode => {NewMu1, NewMu2}},
             [{<<"likelihood">>, <<"quiet">>, L1}, {<<"likelihood">>, <<"maneuver">>, L2},
              {<<"mode">>, <<"quiet">>, NewMu1}, {<<"mode">>, <<"maneuver">>, NewMu2}]}
    end.

%% Switching over Dt seconds: {t11, t12, t21, t22}.
switching(A, B, Dt) ->
    S = A + B,
    L = math:pow(1 - S, Dt),
    T12 = A / S * (1 - L),
    T21 = B / S * (1 - L),
    {1 - T12, T12, T21, 1 - T21}.

%% Mixed state of model j: its own state when cj = 0, else blend(w1, w2) with
%% w1 = t1j*mu1 / cj, w2 = t2j*mu2 / cj.
mix(Cj, _T1jMu1, _T2jMu2, _Model1, _Model2, Own) when Cj == 0 -> Own;
mix(Cj, T1jMu1, T2jMu2, Model1, Model2, _Own) ->
    blend(T1jMu1 / Cj, T2jMu2 / Cj, Model1, Model2).

%% Step 3: g = sum of y*y/s + ln(s) left to right from 0; lambda = -0.5 * g.
likelihood(Terms) ->
    G = lists:foldl(fun({Y, S}, Acc) -> Acc + (Y * Y / S + math:log(S)) end, 0.0, Terms),
    -0.5 * G.

%% Step 4: m is the larger lambda among models with cj above 0;
%% ej = cj * exp(lambdaj - m) (0 when cj is 0); muj = ej / (e1 + e2).
mode(C1, C2, L1, L2) ->
    M = lists:max([L || {C, L} <- [{C1, L1}, {C2, L2}], C > 0]),
    E = fun(C, L) when C > 0 -> C * math:exp(L - M);
           (_, _) -> 0.0
        end,
    E1 = E(C1, L1),
    E2 = E(C2, L2),
    {E1 / (E1 + E2), E2 / (E1 + E2)}.

%% blend(w1, w2) of two filters, per axis (Two-model filter, step 1).
blend(W1, W2, F1, F2) ->
    #{east => blend_axis(W1, W2, maps:get(east, F1), maps:get(east, F2)),
      north => blend_axis(W1, W2, maps:get(north, F1), maps:get(north, F2))}.

blend_axis(W1, W2, {P1, V1, PP1, PV1, VV1}, {P2, V2, PP2, PV2, VV2}) ->
    P = W1 * P1 + W2 * P2,
    V = W1 * V1 + W2 * V2,
    D1 = P1 - P, E1 = V1 - V, D2 = P2 - P, E2 = V2 - V,
    {P, V,
     W1 * (PP1 + D1 * D1) + W2 * (PP2 + D2 * D2),
     W1 * (PV1 + D1 * E1) + W2 * (PV2 + D2 * E2),
     W1 * (VV1 + E1 * E1) + W2 * (VV2 + E2 * E2)}.

%% Prediction of an entity by Dt seconds (Dt may be negative), a copy: one
%% filter as in Track estimate; two models each with its own acceleration
%% variance, combined with the current mode probabilities.
predict(Ent, Dt, Pack) ->
    Q1 = maps:get(<<"accel_var">>, maps:get(filter, Pack)),
    case maps:find(maneuver, Pack) of
        error -> correlator_filter:predict(maps:get(filter, Ent), Dt, Q1);
        {ok, #{<<"accel_var">> := Q2}} ->
            {Model1, Model2} = maps:get(models, Ent),
            {Mu1, Mu2} = maps:get(mode, Ent),
            blend(Mu1, Mu2, correlator_filter:predict(Model1, Dt, Q1),
                  correlator_filter:predict(Model2, Dt, Q2))
    end.
