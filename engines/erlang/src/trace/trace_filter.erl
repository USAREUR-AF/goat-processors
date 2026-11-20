%% Events and trace records of the filter (filter.md "Events", "Trace").
%% Pure constructors.
-module(trace_filter).
-export([reject/1, decision/3, forget/1, rule/8, age/4]).

reject(Reason) -> #{<<"ev">> => <<"reject">>, <<"reason">> => Reason}.

%% keep or drop, with the deciding rule's name.
decision(Action, Key, RuleName) ->
    #{<<"ev">> => atom_to_binary(Action), <<"entity">> => Key, <<"rule">> => RuleName}.

forget(Key) -> #{<<"ev">> => <<"forget">>, <<"entity">> => Key}.

%% One condition's record; unknown adds "unknown": true.
rule(Rule, Key, Test, Negated, Value, Limit, Pass, Unknown) ->
    Base = #{<<"stage">> => <<"rule">>, <<"rule">> => Rule,
             <<"entity">> => Key, <<"test">> => Test,
             <<"negated">> => Negated, <<"value">> => Value, <<"limit">> => Limit,
             <<"pass">> => Pass},
    case Unknown of
        true -> Base#{<<"unknown">> => true};
        false -> Base
    end.

age(Key, Age, Forget, Forgotten) ->
    #{<<"stage">> => <<"forget">>, <<"entity">> => Key,
      <<"test">> => <<"age">>, <<"value">> => Age,
      <<"limit">> => Forget, <<"pass">> => Forgotten}.
