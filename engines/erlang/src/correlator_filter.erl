%% Frame and track estimate (spec "Frame", "Track estimate").
-module(correlator_filter).
-export([to_plane/3, from_plane/3, init/4, update/6, predict/3, velocity/2]).

-define(R, 6371008.8).

rad(X) -> X * math:pi() / 180.
deg(X) -> X * 180 / math:pi().

%% Bring a longitude difference or longitude into (-180, 180].
wrap(X) when X > 180 -> wrap(X - 360);
wrap(X) when X =< -180 -> wrap(X + 360);
wrap(X) -> X.

%% Frame: degrees to metres east and north of {Lat0, Lon0}.
to_plane({Lat0, Lon0}, Lat, Lon) ->
    DLon = wrap(Lon - Lon0),
    {?R * rad(DLon) * math:cos(rad(Lat0)), ?R * rad(Lat - Lat0)}.

%% Frame: back to degrees.
from_plane({Lat0, Lon0}, East, North) ->
    Lat = Lat0 + deg(North / ?R),
    Lon = Lon0 + deg(East / (?R * math:cos(rad(Lat0)))),
    {Lat, wrap(Lon)}.

%% Velocity measurement from course and speed_ms, or none.
velocity(Course, Speed) when is_number(Course), is_number(Speed) ->
    {Speed * math:sin(rad(Course)), Speed * math:cos(rad(Course))};
velocity(_, _) -> none.

%% First report: one axis tuple {P, V, PP, PV, VV} per east and north.
init({E, N}, Vel, Ce, F) ->
    {VE, VN, VV} = case Vel of
                       none -> {0.0, 0.0, sq(maps:get(<<"unknown_vel_ms">>, F))};
                       {X, Y} -> {X, Y, sq(maps:get(<<"vel_sigma_ms">>, F))}
                   end,
    PP = sq(Ce),
    #{east => {E, VE, PP, 0.0, VV}, north => {N, VN, PP, 0.0, VV}}.

%% Later reports: predict, position update, velocity update when measured.
update(Filter, Dt, {E, N}, Vel, Ce, F) ->
    Q = maps:get(<<"accel_var">>, F),
    R = sq(Ce),
    RV = sq(maps:get(<<"vel_sigma_ms">>, F)),
    {ZVE, ZVN} = case Vel of none -> {none, none}; V -> V end,
    #{east => axis(maps:get(east, Filter), Dt, Q, E, R, ZVE, RV),
      north => axis(maps:get(north, Filter), Dt, Q, N, R, ZVN, RV)}.

axis(A0, Dt, Q, Z, R, ZV, RV) ->
    A1 = predict_axis(A0, Dt, Q),
    A2 = position_update(A1, Z, R),
    case ZV of
        none -> A2;
        _ -> velocity_update(A2, ZV, RV)
    end.

%% Step 1, predict.
predict_axis({P, V, PP, PV, VV}, Dt, Q) ->
    {P + V * Dt,
     V,
     PP + 2 * Dt * PV + Dt * Dt * VV + Q * Dt * Dt * Dt * Dt / 4,
     PV + Dt * VV + Q * Dt * Dt * Dt / 2,
     VV + Q * Dt * Dt}.

%% Step 2, position update.
position_update({P, V, PP, PV, VV}, Z, R) ->
    S = PP + R, K1 = PP / S, K2 = PV / S, Y = Z - P,
    {P + K1 * Y, V + K2 * Y, (1 - K1) * PP, (1 - K1) * PV, VV - K2 * PV}.

%% Step 3, velocity update.
velocity_update({P, V, PP, PV, VV}, Z, R) ->
    S = VV + R, K1 = PV / S, K2 = VV / S, Y = Z - V,
    {P + K1 * Y, V + K2 * Y, PP - K1 * PV, (1 - K2) * PV, (1 - K2) * VV}.

%% Prediction of a filter by Dt seconds, a copy.
predict(Filter, Dt, F) ->
    Q = maps:get(<<"accel_var">>, F),
    #{east => predict_axis(maps:get(east, Filter), Dt, Q),
      north => predict_axis(maps:get(north, Filter), Dt, Q)}.

sq(X) -> X * X.
