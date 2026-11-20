%% The input clock and the samples of a report (quality.md "Input clock",
%% "Samples", "Time quality"). The sample functions record their trace
%% record in the state; the input clock and nis_value/5 are pure.
-module(quality_samples).
-export([input_clock/2, source_latest/2, median/1, sample/5, take/5, time_sample/5, nis/7,
         nis_value/5]).

%% Input clock: for each source other than the report's, its latest time is
%% the greatest last among the entities whose source it is; the clock is the
%% median of those times (the mean of the two middle values, in binary64, for
%% an even count), or none with no other source.
input_clock(Source, Entities) ->
    median(lists:sort([L || Src := L <- latest_by_source(Entities), Src =/= Source])).

median([]) -> none;
median(Sorted) ->
    N = length(Sorted),
    case N rem 2 of
        1 -> lists:nth(N div 2 + 1, Sorted);
        0 -> (float(lists:nth(N div 2, Sorted)) + float(lists:nth(N div 2 + 1, Sorted))) / 2
    end.

%% Source latest: the greatest last among the entities whose source is the
%% report's track.source_id (its own entity included when that is its
%% source), or none.
source_latest(Source, Entities) ->
    maps:get(Source, latest_by_source(Entities), none).

%% #{Source => greatest last among its entities}.
latest_by_source(Entities) ->
    maps:fold(fun(_, #{source := Src, last := L}, Acc) ->
                      case Acc of
                          #{Src := M} when M >= L -> Acc;
                          _ -> Acc#{Src => L}
                      end
              end, #{}, Entities).

%% Trace, ingest: one record per sample, preceded by the order.
sample(Key, Name, Value, Inputs, St) ->
    trace_log:record(trace_quality:sample(Key, Name, Value, Inputs), St).

take(Key, Name, Value, Inputs, St) -> {Value, sample(Key, Name, Value, Inputs, St)}.

%% Samples, time_error and time_state (quality.md "Time quality"): the
%% report's valid value, otherwise the time_default's; otherwise unstated, no
%% sample. The trace inputs are [report value, default value].
time_sample(_Key, _Name, null, null, St) -> {null, St};
time_sample(Key, Name, null, Default, St) -> take(Key, Name, Default, [null, Default], St);
time_sample(Key, Name, Own, Default, St) -> take(Key, Name, Own, [Own, Default], St).

%% Samples, nis: the sample and its trace record.
nis(Key, Filter, Dt, Z, Ce, F, St) ->
    {Nis, Inputs} = nis_value(Filter, Dt, Z, Ce, maps:get(<<"accel_var">>, F)),
    take(Key, <<"nis">>, Nis, Inputs, St).

%% Samples, nis: predict to t, compare with the report's position against
%% the predicted plus the reported variance, east then north. Returns
%% {Nis, [De, Dn, Se, Sn]}. Pure.
nis_value(Filter, Dt, {E, N}, Ce, Q) ->
    #{east := {PE, _, PPE, _, _}, north := {PN, _, PPN, _, _}} = model_kalman:predict(Filter, Dt, Q),
    R = Ce * Ce,
    De = E - PE,
    Dn = N - PN,
    Se = PPE + R,
    Sn = PPN + R,
    {De * De / Se + Dn * Dn / Sn, [De, Dn, Se, Sn]}.
