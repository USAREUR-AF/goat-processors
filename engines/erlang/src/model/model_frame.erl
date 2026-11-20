%% Frame (correlate.md "Frame"): the local plane about a reference point,
%% the velocity measurement, the course of a velocity, and the angle and
%% longitude helpers every function uses. Pure.
-module(model_frame).
-export([earth_radius/0, rad/1, deg/1, wrap/1, to_plane/3, from_plane/3, velocity/2,
         course/2]).

-define(R, 6371008.8).

earth_radius() -> ?R.

rad(X) -> X * math:pi() / 180.
deg(X) -> X * 180 / math:pi().

%% Bring a longitude difference or longitude into (-180, 180].
wrap(X) when X > 180 -> wrap(X - 360);
wrap(X) when X =< -180 -> wrap(X + 360);
wrap(X) -> X.

%% Degrees to meters east and north of {Lat0, Lon0}.
to_plane({Lat0, Lon0}, Lat, Lon) ->
    DLon = wrap(Lon - Lon0),
    {?R * rad(DLon) * math:cos(rad(Lat0)), ?R * rad(Lat - Lat0)}.

%% Back to degrees.
from_plane({Lat0, Lon0}, East, North) ->
    Lat = Lat0 + deg(North / ?R),
    Lon = Lon0 + deg(East / (?R * math:cos(rad(Lat0)))),
    {Lat, wrap(Lon)}.

%% Velocity measurement from course and speed_ms, or none.
velocity(Course, Speed) when is_number(Course), is_number(Speed) ->
    {Speed * math:sin(rad(Course)), Speed * math:cos(rad(Course))};
velocity(_, _) -> none.

%% course = deg(atan2(ve, vn)) in [0, 360).
course(VE, VN) ->
    C0 = math:atan2(VE, VN) * 180 / math:pi(),
    if C0 < 0 -> C0 + 360; C0 >= 360 -> C0 - 360; true -> C0 end.
