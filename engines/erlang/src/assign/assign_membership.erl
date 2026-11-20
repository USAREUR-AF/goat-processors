%% Memberships (correlate-assign.md "Memberships"):
%%   membership  #{systems => #{N => [Entity]}, next => N}   (system track sN)
%%   record      #{cost, choices => [[Entity, Chosen]], events, membership}
%%   history     [record], oldest first
%% Membership events take and return {Membership, Events}, the events in the
%% order they happen. Pure.
-module(assign_membership).
-export([empty/0, latest/2, total/1, system_of/2, leave/4, join/3, start/2,
         stale_record/3, apply_assignment/3]).

empty() -> #{systems => #{}, next => 1}.

%% A history's latest membership: its newest record's, or Committed.
latest([], Committed) -> Committed;
latest(History, _Committed) -> maps:get(membership, lists:last(History)).

%% A history's total: its records' costs added left to right from 0, oldest first.
total(History) -> lists:foldl(fun(#{cost := C}, Acc) -> Acc + C end, 0.0, History).

%% The system track A belongs to in a membership, or none.
system_of(A, #{systems := Systems}) ->
    case [S || {S, Ms} <- maps:to_list(Systems), lists:member(A, Ms)] of
        [S] -> S;
        [] -> none
    end.

%% Leave a system track; a system track left empty ends.
leave(A, S, Reason, {Mem = #{systems := Systems}, Evs}) ->
    Ev = trace_assign:leave(S, A, Reason),
    case lists:delete(A, maps:get(S, Systems)) of
        [] -> {Mem#{systems := maps:remove(S, Systems)},
               Evs ++ [Ev, trace_assign:end_system(S)]};
        Rest -> {Mem#{systems := Systems#{S := Rest}}, Evs ++ [Ev]}
    end.

join(A, S, {Mem = #{systems := Systems}, Evs}) ->
    {Mem#{systems := Systems#{S := lists:sort([A | maps:get(S, Systems)])}},
     Evs ++ [trace_assign:join(S, A)]}.

%% Start a new system track alone, named by the membership's counter.
start(A, {Mem = #{systems := Systems, next := S}, Evs}) ->
    {Mem#{systems := Systems#{S => [A]}, next := S + 1}, Evs ++ [trace_assign:start(S, A)]}.

%% Window step 1: a copy of the latest membership with cost 0 and no
%% choices, in which each stale entity leaves its system track and is
%% dropped, then each restarted entity leaves its system track.
stale_record(Mem0, Stale, Restarted) ->
    {Mem1, Evs1} =
        lists:foldl(fun(K, Acc = {M, _}) ->
                            {M1, E1} = case system_of(K, M) of
                                           none -> Acc;
                                           S -> leave(K, S, <<"stale">>, Acc)
                                       end,
                            {M1, E1 ++ [trace_assign:drop(K)]}
                    end, {Mem0, []}, Stale),
    {Mem, Evs} =
        lists:foldl(fun(K, Acc = {M, _}) ->
                            case system_of(K, M) of
                                none -> Acc;
                                S -> leave(K, S, <<"restart">>, Acc)
                            end
                    end, {Mem1, Evs1}, Restarted),
    #{cost => 0.0, choices => [], events => Evs, membership => Mem}.

%% Assignment of one source, step 4, applied to a copy of the newest
%% record: Choices are the entities of R in key order, each
%% {Entity, Chosen, Entry}, and Total the assignment's total.
apply_assignment(Choices, Total, Record) ->
    #{cost := Cost, choices := Choices0, events := Events0, membership := Mem0} = Record,
    {Mem, Events} = lists:foldl(fun({A, B, _}, Acc) -> apply_choice(A, B, Acc) end,
                                {Mem0, []}, Choices),
    Record#{cost := Cost + Total,
            choices := Choices0 ++ [[A, trace_assign:choice_name(B)] || {A, B, _} <- Choices],
            events := Events0 ++ Events,
            membership := Mem}.

apply_choice(A, B, Acc = {Mem = #{systems := Systems}, _}) ->
    Own = system_of(A, Mem),
    Stay = case B of
               alone -> Own =/= none andalso maps:get(Own, Systems) =:= [A];
               S -> Own =:= S
           end,
    case Stay of
        true -> Acc;
        false ->
            Acc1 = case Own of
                       none -> Acc;
                       _ -> leave(A, Own, <<"assign">>, Acc)
                   end,
            case B of
                alone -> start(A, Acc1);
                S2 -> join(A, S2, Acc1)
            end
    end.
