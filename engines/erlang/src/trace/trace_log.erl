%% The output of one engine call (spec/vector-format.md "Scenario vectors"):
%% the events and trace records it gives, kept in the engine state in
%% reverse order while the call runs, then taken out by finish/1. Pure:
%% each function returns a new state.
-module(trace_log).
-export([fields/0, emit/2, emit_all/2, record/2, finish/1]).

%% The two fields every engine state holds for the call in progress.
fields() -> #{events => [], trace => []}.

emit(Ev, St = #{events := Es}) -> St#{events := [Ev | Es]}.
emit_all(Evs, St = #{events := Es}) -> St#{events := lists:reverse(Evs, Es)}.
record(Rec, St = #{trace := Ts}) -> St#{trace := [Rec | Ts]}.

%% {Events, Trace, State}: the call's output in order, and the state ready
%% for the next call.
finish(St = #{events := Es, trace := Ts}) ->
    {lists:reverse(Es), lists:reverse(Ts), St#{events := [], trace := []}}.
