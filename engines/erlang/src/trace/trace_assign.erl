%% Events and trace records of method assign (correlate-assign.md "Events",
%% "Trace"). Pure constructors.
-module(trace_assign).
-export([system_name/1, leave/3, end_system/1, join/2, start/2, drop/1, provisional/2,
         assign/5, history/5, choice_name/1, bias/7]).

system_name(S) -> <<"s", (integer_to_binary(S))/binary>>.

leave(S, A, Reason) ->
    #{<<"ev">> => <<"leave">>, <<"system">> => system_name(S), <<"entity">> => A,
      <<"reason">> => Reason}.
end_system(S) -> #{<<"ev">> => <<"end">>, <<"system">> => system_name(S)}.
join(S, A) -> #{<<"ev">> => <<"join">>, <<"system">> => system_name(S), <<"entity">> => A}.
start(S, A) -> #{<<"ev">> => <<"start">>, <<"system">> => system_name(S), <<"entity">> => A}.
drop(K) -> #{<<"ev">> => <<"drop">>, <<"entity">> => K}.
provisional(S, Ms) ->
    #{<<"ev">> => <<"provisional">>, <<"system">> => system_name(S), <<"members">> => Ms}.

%% A system track's name or "alone".
choice_name(alone) -> <<"alone">>;
choice_name(S) -> system_name(S).

%% Stage assign: a cost or choice record; a forbidden entry has value null.
assign(A, B, Test, Cost, Pass) ->
    #{<<"stage">> => <<"assign">>, <<"a">> => A, <<"b">> => choice_name(B),
      <<"test">> => Test,
      <<"value">> => case Cost of forbidden -> null; _ -> Cost end,
      <<"limit">> => null, <<"pass">> => Pass}.

%% Stage history: a total or commit record.
history(A, B, Test, Value, Pass) ->
    #{<<"stage">> => <<"history">>, <<"a">> => A, <<"b">> => B, <<"test">> => Test,
      <<"value">> => Value, <<"limit">> => null, <<"pass">> => Pass}.

%% Stage bias: one pair's offset test, with the pair's state after it.
bias(X, Y, D2, Gate, Accepted, State, TimeOffset) ->
    Rec = #{<<"stage">> => <<"bias">>, <<"a">> => X, <<"b">> => Y, <<"test">> => <<"offset">>,
            <<"value">> => D2, <<"limit">> => Gate, <<"pass">> => Accepted,
            <<"east">> => maps:get(oe, State), <<"north">> => maps:get(on, State),
            <<"var">> => maps:get(var, State), <<"pairs">> => maps:get(n, State)},
    case TimeOffset of
        true -> Rec#{<<"time_offset_ms">> => maps:get(tau, State) * 1000};
        false -> Rec
    end.
