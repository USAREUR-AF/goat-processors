%% Unit tests of src/model: reports, frame, Kalman filter, two-model filter.
-module(model_tests).
-include_lib("eunit/include/eunit.hrl").

report() ->
    #{<<"track.source_id">> => <<"radar-1">>, <<"uid">> => <<"T1">>, <<"time_ms">> => 1000,
      <<"lat">> => 50.0, <<"lon">> => 8.0}.

%% ---------------------------------------------------------------- model_report

first_missing_in_table_order_test() ->
    ?assertEqual(none, model_report:first_missing(report())),
    ?assertEqual(<<"uid">>, model_report:first_missing(maps:remove(<<"uid">>, report()))),
    %% the first in table order, not in map order
    R = maps:without([<<"lon">>, <<"track.source_id">>], report()),
    ?assertEqual(<<"track.source_id">>, model_report:first_missing(R)),
    %% a wrong type is missing; a float time is not an integer
    ?assertEqual(<<"time_ms">>, model_report:first_missing((report())#{<<"time_ms">> := 1.0})),
    ?assertEqual(<<"lat">>, model_report:first_missing((report())#{<<"lat">> := true})).

validate_test() ->
    ?assertEqual({reject, <<"missing:lat">>}, model_report:validate(maps:remove(<<"lat">>, report()))),
    {ok, N} = model_report:validate((report())#{<<"ce">> => 0, <<"hae">> => null,
                                               <<"course">> => <<"n">>, <<"x">> => 1,
                                               <<"speed_ms">> => 3}),
    ?assertEqual(false, maps:is_key(<<"ce">>, N)),        % ce 0 is absent
    ?assertEqual(false, maps:is_key(<<"hae">>, N)),       % null is absent
    ?assertEqual(false, maps:is_key(<<"course">>, N)),    % wrong type
    ?assertEqual(1, maps:get(<<"x">>, N)),                % other keys kept
    ?assertEqual(3, maps:get(<<"speed_ms">>, N)).

normalize_extra_table_test() ->
    T = [{<<"g">>, nonempty_string}],
    ?assertEqual(#{}, model_report:normalize(#{<<"g">> => <<>>}, T)),
    ?assertEqual(#{<<"g">> => <<"a">>}, model_report:normalize(#{<<"g">> => <<"a">>}, T)).

entity_key_test() ->
    ?assertEqual(<<"radar-1/T1">>, model_report:entity_key(report())).

time_keys_test() ->
    Defaults = #{<<"radar-1">> => #{<<"error_ms">> => 5, <<"state">> => <<"drifting">>}},
    ?assertEqual({{null, 5}, {null, <<"drifting">>}}, model_report:time_keys(report(), Defaults)),
    R = (report())#{<<"time_error_ms">> => 2.5, <<"time_state">> => <<"free-running">>},
    ?assertEqual({{2.5, null}, {<<"free-running">>, null}}, model_report:time_keys(R, #{})),
    Bad = (report())#{<<"time_error_ms">> => -1, <<"time_state">> => <<"Coherent">>},
    ?assertEqual({{null, null}, {null, null}}, model_report:time_keys(Bad, #{})).

first_given_test() ->
    ?assertEqual(3, model_report:first_given([null, 3, 4], 0)),
    ?assertEqual(0, model_report:first_given([null, null], 0)).

type_element_test() ->
    ?assertEqual(<<"A">>, model_report:type_element(env, <<"a-f-A-M">>)),
    ?assertEqual(null, model_report:type_element(env, <<"a-f">>)),
    ?assertEqual(<<"h">>, model_report:type_element(affiliation, <<"a-h-G">>)),
    ?assertEqual(null, model_report:type_element(affiliation, <<"b-h-G">>)),
    ?assertEqual(null, model_report:type_element(env, null)).

%% ---------------------------------------------------------------- model_frame

wrap_test() ->
    ?assertEqual(180, model_frame:wrap(180)),
    ?assertEqual(180, model_frame:wrap(-180)),
    ?assertEqual(-170, model_frame:wrap(190)),
    ?assertEqual(10, model_frame:wrap(730)).

plane_round_trip_test() ->
    Ref = {50.0, 8.0},
    {E, N} = model_frame:to_plane(Ref, 50.01, 8.02),
    ?assert(E > 0 andalso N > 0),
    {Lat, Lon} = model_frame:from_plane(Ref, E, N),
    ?assert(abs(Lat - 50.01) < 1.0e-9),
    %% from_plane scales east by cos(lat0), to_plane by cos(lat0) too
    ?assert(abs(Lon - 8.02) < 1.0e-9),
    ?assertEqual({0.0, 0.0}, model_frame:to_plane(Ref, 50.0, 8.0)).

antimeridian_test() ->
    {E, _} = model_frame:to_plane({0.0, 179.9}, 0.0, -179.9),
    ?assert(E > 0 andalso E < 30000).

velocity_and_course_test() ->
    ?assertEqual(none, model_frame:velocity(null, 3)),
    {VE, VN} = model_frame:velocity(90, 10),
    ?assert(abs(VE - 10) < 1.0e-9 andalso abs(VN) < 1.0e-9),
    ?assert(abs(model_frame:course(VE, VN) - 90) < 1.0e-9),
    ?assert(abs(model_frame:course(-1.0, 0.0) - 270) < 1.0e-9),
    ?assertEqual(0.0, model_frame:course(0.0, 1.0)).

%% ---------------------------------------------------------------- model_kalman

filter_params() ->
    #{<<"accel_var">> => 1, <<"default_ce_m">> => 50, <<"vel_sigma_ms">> => 5,
      <<"unknown_vel_ms">> => 100}.

init_test() ->
    F = model_kalman:init({1.0, 2.0}, none, 10, filter_params()),
    ?assertEqual(#{east => {1.0, 0.0, 100, 0.0, 10000}, north => {2.0, 0.0, 100, 0.0, 10000}}, F),
    G = model_kalman:init_r({1.0, 2.0}, {3.0, 4.0}, {9, 16}, filter_params()),
    ?assertEqual(#{east => {1.0, 3.0, 9, 0.0, 25}, north => {2.0, 4.0, 16, 0.0, 25}}, G).

predict_zero_dt_is_identity_test() ->
    F = model_kalman:init({1.0, 2.0}, {3.0, 4.0}, 10, filter_params()),
    #{east := E, north := N} = model_kalman:predict(F, 0.0, 1),
    ?assert(tuple_to_list(E) == tuple_to_list(maps:get(east, F))),
    ?assert(tuple_to_list(N) == tuple_to_list(maps:get(north, F))).

predict_moves_and_grows_test() ->
    F = model_kalman:init({0.0, 0.0}, {3.0, 4.0}, 10, filter_params()),
    #{east := {PE, VE, PPE, _, _}, north := {PN, _, _, _, _}} = model_kalman:predict(F, 2.0, 1),
    ?assertEqual(6.0, PE), ?assertEqual(8.0, PN), ?assertEqual(3.0, VE),
    ?assert(PPE > 100).

update_shrinks_variance_and_returns_innovations_test() ->
    F0 = model_kalman:init({0.0, 0.0}, none, 10, filter_params()),
    {F1, Terms} = model_kalman:update(F0, 1.0, 1, {5.0, 5.0}, none, 10, filter_params()),
    ?assertEqual(2, length(Terms)),
    #{east := {P, _, PP, _, _}} = F1,
    ?assert(P > 0 andalso P < 5.0),
    ?assert(PP < 100),
    {_, Terms4} = model_kalman:update(F0, 1.0, 1, {5.0, 5.0}, {1.0, 1.0}, 10, filter_params()),
    ?assertEqual(4, length(Terms4)).

%% ---------------------------------------------------------------- model_imm

imm_pack() ->
    #{filter => filter_params(),
      maneuver => #{<<"accel_var">> => 400, <<"p_enter">> => 0.05, <<"p_leave">> => 0.1}}.

imm_init_mode_test() ->
    E = model_imm:init({0.0, 0.0}, none, {100, 100}, imm_pack()),
    {Mu1, Mu2} = maps:get(mode, E),
    ?assert(abs(Mu1 - 0.1 / 0.15) < 1.0e-12),
    ?assert(abs(Mu1 + Mu2 - 1) < 1.0e-12),
    ?assertEqual(false, maps:is_key(models, model_imm:init({0.0, 0.0}, none, {1, 1},
                                                           #{filter => filter_params()}))).

imm_update_records_and_mode_sum_test() ->
    E0 = model_imm:init({0.0, 0.0}, none, {100, 100}, imm_pack()),
    {E1, Records} = model_imm:update(E0, 1.0, {30.0, 0.0}, none, {100, 100}, imm_pack()),
    ?assertEqual([<<"likelihood">>, <<"likelihood">>, <<"mode">>, <<"mode">>],
                 [T || {T, _, _} <- Records]),
    {Mu1, Mu2} = maps:get(mode, E1),
    ?assert(abs(Mu1 + Mu2 - 1) < 1.0e-12),
    {_, []} = model_imm:update(maps:with([filter], E0), 1.0, {1.0, 0.0}, none, {1, 1},
                               #{filter => filter_params()}).

imm_predict_blends_test() ->
    E0 = model_imm:init({0.0, 0.0}, {1.0, 0.0}, {100, 100}, imm_pack()),
    #{east := {P, _, _, _, _}} = model_imm:predict(E0, 1.0, imm_pack()),
    ?assert(abs(P - 1.0) < 1.0e-12).
