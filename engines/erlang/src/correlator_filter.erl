%% Frame and the one-model track estimate (correlate.md "Frame", "Track estimate").
-module(correlator_filter).
-export([to_plane/3, from_plane/3, init/4, update/7, predict/3, velocity/2]).

-define(R, 6371008.8).

rad(X) -> X * math:pi() / 180.
deg(X) -> X * 180 / math:pi().

%% Bring a longitude difference or longitude into (-180, 180].
wrap(X) when X > 180 -> wrap(X - 360);
wrap(X) when X =< -180 -> wrap(X + 360);
wrap(X) -> X.

%% Frame: degrees to meters east and north of {Lat0, Lon0}.
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

%% Later reports: steps 1 to 3 with acceleration variance Q. Returns the new
%% filter and the innovations {Y, S} of its scalar updates in the order east
%% position, north position, then (velocity measured) east and north velocity,
%% the order Two-model filter step 3 adds them in.
update(Filter, Dt, Q, {E, N}, Vel, Ce, F) ->
    R = sq(Ce),
    RV = sq(maps:get(<<"vel_sigma_ms">>, F)),
    {EastPos, YSEP} = position_update(predict_axis(maps:get(east, Filter), Dt, Q), E, R),
    {NorthPos, YSNP} = position_update(predict_axis(maps:get(north, Filter), Dt, Q), N, R),
    case Vel of
        none ->
            {#{east => EastPos, north => NorthPos}, [YSEP, YSNP]};
        {VE, VN} ->
            {East, YSEV} = velocity_update(EastPos, VE, RV),
            {North, YSNV} = velocity_update(NorthPos, VN, RV),
            {#{east => East, north => North}, [YSEP, YSNP, YSEV, YSNV]}
    end.

%% Step 1, predict.
predict_axis({P, V, PP, PV, VV}, Dt, Q) ->
    {P + V * Dt,
     V,
     PP + 2 * Dt * PV + Dt * Dt * VV + Q * Dt * Dt * Dt * Dt / 4,
     PV + Dt * VV + Q * Dt * Dt * Dt / 2,
     VV + Q * Dt * Dt}.

%% Step 2, position update; returns the axis and {Y, S}.
position_update({P, V, PP, PV, VV}, Z, R) ->
    S = PP + R, K1 = PP / S, K2 = PV / S, Y = Z - P,
    {{P + K1 * Y, V + K2 * Y, (1 - K1) * PP, (1 - K1) * PV, VV - K2 * PV}, {Y, S}}.

%% Step 3, velocity update; returns the axis and {Y, S}.
velocity_update({P, V, PP, PV, VV}, Z, R) ->
    S = VV + R, K1 = PV / S, K2 = VV / S, Y = Z - V,
    {{P + K1 * Y, V + K2 * Y, PP - K1 * PV, (1 - K2) * PV, (1 - K2) * VV}, {Y, S}}.

%% Prediction of a filter by Dt seconds with acceleration variance Q, a copy.
predict(Filter, Dt, Q) ->
    #{east => predict_axis(maps:get(east, Filter), Dt, Q),
      north => predict_axis(maps:get(north, Filter), Dt, Q)}.

sq(X) -> X * X.
