%% Geometry (filter.md "Geometry"): distance, the reference prediction and
%% the polygon test. Pure.
-module(filter_geometry).
-export([distance/4, predict/2, polygon/3]).

-import(model_frame, [rad/1, deg/1, wrap/1]).

%% Distance (haversine), steps 1 to 4; point 1 is the report.
distance(Lat1, Lon1, Lat2, Lon2) ->
    P1 = rad(Lat1),
    P2 = rad(Lat2),
    Dp = rad(Lat2 - Lat1),
    Dl = rad(wrap(Lon2 - Lon1)),
    S1 = math:sin(Dp / 2),
    S2 = math:sin(Dl / 2),
    H = S1 * S1 + ((math:cos(P1) * math:cos(P2)) * S2) * S2,
    (2 * model_frame:earth_radius()) * math:asin(min(1, math:sqrt(H))).

%% Reference prediction to time T, steps 1 to 3.
predict(#{time_ms := T0, lat := Lat, lon := Lon, course := Course, speed_ms := Speed}, T) ->
    R = model_frame:earth_radius(),
    Dt = (T - T0) / 1000,
    {Dn, De} = case Course =/= null andalso Speed =/= null of
                   true -> {Speed * math:cos(rad(Course)) * Dt,
                            Speed * math:sin(rad(Course)) * Dt};
                   false -> {0, 0}
               end,
    {Lat + deg(Dn / R), wrap(Lon + deg(De / (R * math:cos(rad(Lat)))))}.

%% Polygon: unwrap longitudes about the first vertex, then the boundary step,
%% then crossings (even-odd). Returns boundary | inside | outside.
polygon(Vertices = [{_, Lon0} | _], Lat, Lon) ->
    Points = [{Lon0 + wrap(VLon - Lon0), VLat} || {VLat, VLon} <- Vertices],
    Px = Lon0 + wrap(Lon - Lon0),
    Py = Lat,
    Edges = lists:zip(Points, tl(Points) ++ [hd(Points)]),
    case lists:any(fun(E) -> on_edge(E, Px, Py) end, Edges) of
        true -> boundary;
        false ->
            case lists:foldl(fun(E, In) -> crosses(E, Px, Py) xor In end, false, Edges) of
                true -> inside;
                false -> outside
            end
    end.

%% Boundary: c == 0 exactly and the point within the edge's bounding box.
on_edge({{Xi, Yi}, {Xj, Yj}}, Px, Py) ->
    C = (Xj - Xi) * (Py - Yi) - (Yj - Yi) * (Px - Xi),
    C == 0 andalso min(Xi, Xj) =< Px andalso Px =< max(Xi, Xj)
        andalso min(Yi, Yj) =< Py andalso Py =< max(Yi, Yj).

%% Crossings: the edge straddles py and the crossing is right of px.
crosses({{Xi, Yi}, {Xj, Yj}}, Px, Py) ->
    case (Yi > Py) =/= (Yj > Py) of
        true -> Px < (Xj - Xi) * (Py - Yi) / (Yj - Yi) + Xi;
        false -> false
    end.
