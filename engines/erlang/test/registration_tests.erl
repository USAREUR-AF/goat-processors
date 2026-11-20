%% The registration point of a correlate test kind (correlate_test_kinds):
%% a no-op test kind, `noop`, registered here only, by one entry passed to
%% correlate:load_pack/2. It takes no parameter and always passes.
%%  - Invisible: every correlate vector, loaded with the kind registered,
%%    gives the output it gives without it.
%%  - Its own test: the fixture pack test/fixtures/correlate-noop (correlate-gnn
%%    with `gate noop` first) gives correlate-gnn's events on correlate-gnn's
%%    vectors, and each gate run gets one more record, the noop's, first.
%%  - Without the registration the fixture does not load (unknown test).
-module(registration_tests).
-include_lib("eunit/include/eunit.hrl").
-export([noop/2]).

noop(_Params, _View) ->
    {true, #{<<"test">> => <<"noop">>, <<"value">> => null, <<"limit">> => null}}.

extension() ->
    #{tests => #{<<"noop">> => #{params => [], values => number, run => fun ?MODULE:noop/2}}}.

fixture() -> filename:join(filename:dirname(code:which(?MODULE)), "../fixtures/correlate-noop").

run(Dir, Ext, Steps) ->
    {ok, Pack} = correlate:load_pack(Dir, Ext),
    test_support:run_from(correlate, correlate:new(Pack), Steps).

invisible_to_every_vector_test_() ->
    {timeout, 300,
     [{filename:basename(F),
       fun() ->
               Steps = test_support:steps(F),
               ?assertEqual(run(Dir, #{}, Steps), run(Dir, extension(), Steps))
       end} || {_, _, Dir, F} <- test_support:scenarios(<<"correlate">>)]}.

unregistered_does_not_load_test() ->
    ?assertEqual({error, {unknown_test, <<"noop">>}}, correlate:load_pack(fixture())).

noop_gate_test_() ->
    Gnn = filename:join(test_support:root(), "packs/correlate-gnn"),
    [{filename:basename(F),
      fun() ->
              Steps = test_support:steps(F),
              {WantOut, WantSnap} = run(Gnn, #{}, Steps),
              {Out, Snap} = run(fixture(), extension(), Steps),
              ?assertEqual(WantSnap, Snap),
              ?assertEqual([E || {E, _} <- WantOut], [E || {E, _} <- Out]),
              [?assertEqual(Want, without_noop(Got)) || {{_, Want}, {_, Got}} <- lists:zip(WantOut, Out)],
              %% one noop record before each gate run's first record
              [check_order(T) || {_, T} <- Out]
      end} || F <- gnn_vectors(Gnn)].

%% The noop kind does run: its records are in the trace.
noop_records_test() ->
    Gnn = filename:join(test_support:root(), "packs/correlate-gnn"),
    Records = [R || F <- gnn_vectors(Gnn),
                    {_, T} <- element(1, run(fixture(), extension(), test_support:steps(F))),
                    R = #{<<"test">> := <<"noop">>} <- T],
    ?assert(length(Records) > 10),
    ?assert(lists:all(fun(#{<<"pass">> := P, <<"value">> := V}) -> P andalso V =:= null end,
                      Records)).

gnn_vectors(Gnn) -> lists:sort(filelib:wildcard(filename:join(Gnn, "vectors/*.json"))).

without_noop(Trace) -> [R || R <- Trace, maps:get(<<"test">>, R) =/= <<"noop">>].

%% Each gate mahalanobis record is right after a noop record of the same pair.
check_order([]) -> ok;
check_order([#{<<"test">> := <<"noop">>, <<"stage">> := <<"gate">>, <<"a">> := A, <<"b">> := B,
               <<"pass">> := true},
             #{<<"test">> := <<"mahalanobis">>, <<"stage">> := <<"gate">>, <<"a">> := A,
               <<"b">> := B} | Rest]) -> check_order(Rest);
check_order([#{<<"test">> := <<"noop">>} | _] = T) -> ?assertEqual(noop_then_mahalanobis, T);
check_order([#{<<"stage">> := <<"gate">>, <<"test">> := <<"mahalanobis">>} | _] = T) ->
    ?assertEqual(noop_first, T);
check_order([_ | Rest]) -> check_order(Rest).
