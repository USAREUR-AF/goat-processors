%% The track estimate of one report (correlate.md "Reports" Time quality,
%% "Track estimate" Measurement variance, "Restart"): the time error and
%% state, the measurement variance and timing variance, and the restart test.
-module(correlate_track).
-export([report_ce/2, time_quality/2, measurement_variance/7, restart_test/6, add_timing/2]).

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

%% Track estimate, "Measurement variance". Returns {R, Timing, St} with
%% R = {r_east, r_north} and Timing = {(v_e*ts)², (v_n*ts)²}:
%% with te = 0, r = ce² on both axes and the timing variance 0 and 0;
%% otherwise ts = te / 1000, (v_e, v_n) the entity's prediction to the
%% report's time_ms (first report: the measured velocity, or 0 without one),
%% r = ce² + (v*ts)² per axis, and the trace gets the "time" filter record.
measurement_variance(_Key, _Found, _T, _Vel, Ce, Te, St) when Te == 0 ->
    {{Ce * Ce, Ce * Ce}, {0.0, 0.0}, St};
measurement_variance(Key, Found, T, Vel, Ce, Te, St) ->
    {VE, VN} = case Found of
                   error when Vel =:= none -> {0.0, 0.0};
                   error -> Vel;
                   {ok, Ent} ->
                       #{east := {_, PredVE, _, _, _}, north := {_, PredVN, _, _, _}} =
                           correlate:predict(Ent, T, St),
                       {PredVE, PredVN}
               end,
    Ts = Te / 1000,
    VarE = (VE * Ts) * (VE * Ts),
    VarN = (VN * Ts) * (VN * Ts),
    {{Ce * Ce + VarE, Ce * Ce + VarN}, {VarE, VarN},
     trace_log:record(trace_correlate:time(Key, Te, VarE, VarN), St)}.

%% Restart (correlate.md "Restart"), for a later report of an entity: with
%% the pack's restart line, predict the entity to the report's time and
%% d² = (e - pe)² / (pp_e + r_east) + (n - pn)² / (pp_n + r_north), the
%% prediction without any timing variance; one filter record after the
%% "time" record and before any other record of the report; passes when
%% d² < gate. Without the line the report always updates the filter.
restart_test(Key, Ent, T, {E, N}, {RE, RN}, St) ->
    case maps:find(restart, maps:get(pack, St)) of
        error -> {true, St};
        {ok, #{<<"gate">> := Gate}} ->
            #{east := {PE, _, PPE, _, _}, north := {PN, _, PPN, _, _}} =
                correlate:predict(Ent, T, St),
            D2 = (E - PE) * (E - PE) / (PPE + RE) + (N - PN) * (N - PN) / (PPN + RN),
            Pass = D2 < Gate,
            {Pass, trace_log:record(trace_correlate:restart(Key, D2, Gate, Pass), St)}
    end.

%% A prediction compared with another entity: the timing variance
%% {VarE, VarN} added to pp on each axis.
add_timing(Pred = #{east := {PE, VE, PPE, PVE, VVE}, north := {PN, VN, PPN, PVN, VVN}},
           {VarE, VarN}) ->
    Pred#{east := {PE, VE, PPE + VarE, PVE, VVE}, north := {PN, VN, PPN + VarN, PVN, VVN}}.
