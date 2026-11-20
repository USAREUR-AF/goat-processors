%% Events and trace records of quality (quality.md "Events", "Trace").
%% Pure constructors.
-module(trace_quality).
-export([reject/1, new/1, forget_entity/1, forget_source/1, quality/3, pass/3,
         action_start/3, action_end/4, sample/4, rule/7]).

reject(Reason) -> #{<<"ev">> => <<"reject">>, <<"reason">> => Reason}.
new(Key) -> #{<<"ev">> => <<"new">>, <<"entity">> => Key}.
forget_entity(Key) -> #{<<"ev">> => <<"forget">>, <<"entity">> => Key}.
forget_source(Src) -> #{<<"ev">> => <<"forget">>, <<"source">> => Src}.

quality(Scope, Subject, Ms) ->
    #{<<"ev">> => <<"quality">>, <<"scope">> => Scope, <<"subject">> => Subject,
      <<"measures">> => Ms}.

%% The pass event: withheld, or the forwarded report.
pass(Key, Names, withheld) ->
    #{<<"ev">> => <<"pass">>, <<"entity">> => Key, <<"rules">> => Names,
      <<"withheld">> => true};
pass(Key, Names, Report) ->
    #{<<"ev">> => <<"pass">>, <<"entity">> => Key, <<"rules">> => Names,
      <<"withheld">> => false, <<"report">> => Report}.

action_start(#{name := N, scope := S, action := A}, Subject, V) ->
    #{<<"ev">> => <<"action-start">>, <<"rule">> => N, <<"scope">> => atom_to_binary(S),
      <<"subject">> => Subject, <<"action">> => A, <<"value">> => V}.

action_end(#{name := N, scope := S, action := A}, Subject, Reason, V) ->
    #{<<"ev">> => <<"action-end">>, <<"rule">> => N, <<"scope">> => atom_to_binary(S),
      <<"subject">> => Subject, <<"action">> => A, <<"reason">> => Reason, <<"value">> => V}.

sample(Key, Name, Value, Inputs) ->
    #{<<"stage">> => <<"sample">>, <<"entity">> => Key, <<"sample">> => Name,
      <<"value">> => Value, <<"inputs">> => Inputs}.

rule(Name, Subject, Measure, V, Limit, Pass, #{count := C, active := A}) ->
    #{<<"stage">> => <<"rule">>, <<"rule">> => Name, <<"subject">> => Subject,
      <<"measure">> => Measure, <<"value">> => V, <<"limit">> => Limit, <<"pass">> => Pass,
      <<"count">> => C, <<"active">> => A}.
