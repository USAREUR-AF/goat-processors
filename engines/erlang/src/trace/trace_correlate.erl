%% Events and trace records of correlate.md ("Events", "Trace") that both
%% methods give: reject and new, and the filter, test, rank and count
%% records; the confirm method's group events and sequential test records
%% (correlate.md 1.0). Pure constructors.
-module(trace_correlate).
-export([reject/1, reject/2, new/1, filter/4, time/4, restart/4, test/5, skipped/1,
         result/3, rank/3, count/5, llr/7, group_name/1, correlate/2, join/2, leave/3, dissolve/2,
         drop/1]).

reject(Reason) -> #{<<"ev">> => <<"reject">>, <<"reason">> => Reason}.
reject(Key, Reason) -> #{<<"ev">> => <<"reject">>, <<"entity">> => Key, <<"reason">> => Reason}.
new(Key) -> #{<<"ev">> => <<"new">>, <<"entity">> => Key}.
drop(Key) -> #{<<"ev">> => <<"drop">>, <<"entity">> => Key}.

%% Two-model filter, Trace: a likelihood or mode record of one model.
filter(Key, Test, Model, Value) ->
    #{<<"stage">> => <<"filter">>, <<"a">> => Key, <<"b">> => Model,
      <<"test">> => Test, <<"value">> => Value, <<"limit">> => null, <<"pass">> => true}.

%% Track estimate, Measurement variance: the "time" filter record.
time(Key, Te, VarE, VarN) ->
    #{<<"stage">> => <<"filter">>, <<"a">> => Key, <<"b">> => null,
      <<"test">> => <<"time">>, <<"value">> => Te, <<"limit">> => null,
      <<"pass">> => true, <<"var_east">> => VarE, <<"var_north">> => VarN}.

%% Restart: the "restart" filter record.
restart(Key, D2, Gate, Pass) ->
    #{<<"stage">> => <<"filter">>, <<"a">> => Key, <<"b">> => null,
      <<"test">> => <<"restart">>, <<"value">> => D2, <<"limit">> => Gate, <<"pass">> => Pass}.

%% Tests: a test's result {Pass, Fields} as a record of a stage.
test(Stage, A, B, Pass, Fields) ->
    Fields#{<<"stage">> => Stage, <<"a">> => A, <<"b">> => B, <<"pass">> => Pass}.

result(Name, Value, Limit) ->
    #{<<"test">> => Name, <<"value">> => Value, <<"limit">> => Limit}.

skipped(Name) ->
    #{<<"test">> => Name, <<"value">> => null, <<"limit">> => null, <<"skipped">> => true}.

rank(A, B, D2) ->
    #{<<"stage">> => <<"rank">>, <<"a">> => A, <<"b">> => B, <<"test">> => <<"rank">>,
      <<"value">> => D2, <<"limit">> => null, <<"pass">> => true}.

count(A, B, N, CC, Pass) ->
    #{<<"stage">> => <<"confirm">>, <<"a">> => A, <<"b">> => B,
      <<"test">> => <<"count">>, <<"value">> => N, <<"limit">> => CC, <<"pass">> => Pass}.

%% Association, Sequential test: the update of a pair.
llr(A, B, L, Up, Lo, Inc, D2) ->
    #{<<"stage">> => <<"sprt">>, <<"a">> => A, <<"b">> => B, <<"test">> => <<"llr">>,
      <<"value">> => L, <<"limit">> => Up, <<"pass">> => L >= Up, <<"lower">> => Lo,
      <<"increment">> => Inc, <<"d2">> => D2}.

group_name(G) -> <<"g", (integer_to_binary(G))/binary>>.

correlate(G, Ms) ->
    #{<<"ev">> => <<"correlate">>, <<"group">> => group_name(G), <<"members">> => Ms}.
join(G, A) -> #{<<"ev">> => <<"join">>, <<"group">> => group_name(G), <<"entity">> => A}.
leave(G, A, Reason) ->
    #{<<"ev">> => <<"leave">>, <<"group">> => group_name(G), <<"entity">> => A,
      <<"reason">> => Reason}.
dissolve(G, Last) ->
    #{<<"ev">> => <<"dissolve">>, <<"group">> => group_name(G), <<"entity">> => Last}.
