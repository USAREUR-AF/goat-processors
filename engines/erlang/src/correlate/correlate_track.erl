%% The track estimate of one report (correlate.md "Reports" Time quality,
%% "Track estimate" Measurement variance, "Restart"): the time error and
%% state, the measurement variance and timing variance, and the restart test.
%% Pure functions of the report, the entity and the pack.
-module(correlate_track).
-export([report_ce/2, time_quality/2, measurement_variance/6, restart/5, add_timing/2]).

%% The report's ce, or the filter line's default_ce_m.
report_ce(Report, F) ->
    case maps:get(<<"ce">>, Report, null) of
        null -> maps:get(<<"default_ce_m">>, F);
        Ce -> Ce
    end.

%% Reports, "Time quality": {TimeError, TimeState} of a report, each key
%% found independently by steps 1 and 2 (model_report:time_keys/2); at step
%% 3, when neither gives a value, time error 0 and state coherent. Correlate
%% keeps the time state but does not use it in this version.
time_quality(Report, Pack) ->
    {{ReportTe, DefaultTe}, {ReportState, DefaultState}} =
        model_report:time_keys(Report, maps:get(time_default, Pack)),
    {model_report:first_given([ReportTe, DefaultTe], 0),
     model_report:first_given([ReportState, DefaultState], <<"coherent">>)}.

%% Track estimate, "Measurement variance". Returns {R, Timing, TimeRecord}
%% with R = {r_east, r_north}, Timing = {(v_e*ts)², (v_n*ts)²} and
%% TimeRecord none or {VarE, VarN} for the "time" filter record: with
%% te = 0, r = ce² on both axes, the timing variance 0 and 0 and no record;
%% otherwise ts = te / 1000, (v_e, v_n) the entity's prediction to the
%% report's time_ms (first report: the measured velocity, or 0 without one),
%% r = ce² + (v*ts)² per axis. Pure.
measurement_variance(_Found, _T, _Vel, Ce, Te, _Pack) when Te == 0 ->
    {{Ce * Ce, Ce * Ce}, {0.0, 0.0}, none};
measurement_variance(Found, T, Vel, Ce, Te, Pack) ->
    {VE, VN} = case Found of
                   error when Vel =:= none -> {0.0, 0.0};
                   error -> Vel;
                   {ok, Ent} ->
                       #{east := {_, PredVE, _, _, _}, north := {_, PredVN, _, _, _}} =
                           correlate:predict(Ent, T, Pack),
                       {PredVE, PredVN}
               end,
    Ts = Te / 1000,
    VarE = (VE * Ts) * (VE * Ts),
    VarN = (VN * Ts) * (VN * Ts),
    {{Ce * Ce + VarE, Ce * Ce + VarN}, {VarE, VarN}, {VarE, VarN}}.

%% Restart (correlate.md "Restart"), for a later report of an entity: with
%% the pack's restart line, predict the entity to the report's time and
%% d² = (e - pe)² / (pp_e + r_east) + (n - pn)² / (pp_n + r_north), the
%% prediction without any timing variance; passes when d² < gate. Returns
%% {D2, Gate, Pass}, or none without the line (the report always updates
%% the filter). Pure.
restart(Ent, T, {E, N}, {RE, RN}, Pack) ->
    case maps:find(restart, Pack) of
        error -> none;
        {ok, #{<<"gate">> := Gate}} ->
            #{east := {PE, _, PPE, _, _}, north := {PN, _, PPN, _, _}} =
                correlate:predict(Ent, T, Pack),
            D2 = (E - PE) * (E - PE) / (PPE + RE) + (N - PN) * (N - PN) / (PPN + RN),
            {D2, Gate, D2 < Gate}
    end.

%% A prediction compared with another entity: the timing variance
%% {VarE, VarN} added to pp on each axis.
add_timing(Pred = #{east := {PE, VE, PPE, PVE, VVE}, north := {PN, VN, PPN, PVN, VVN}},
           {VarE, VarN}) ->
    Pred#{east := {PE, VE, PPE + VarE, PVE, VVE}, north := {PN, VN, PPN + VarN, PVN, VVN}}.
