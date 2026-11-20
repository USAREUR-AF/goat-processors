%% Events and trace records of fuse (fuse.md "Events", "Trace"). Pure
%% constructors.
-module(trace_fuse).
-export([reject/1, stale_report/3, new/2, move/3, drop/2, intersect/3, candidate/4,
         kinematics/4, attribute/6]).

reject(Reason) -> #{<<"ev">> => <<"reject">>, <<"reason">> => Reason}.
stale_report(Key, T, Last) ->
    #{<<"ev">> => <<"stale-report">>, <<"entity">> => Key, <<"time_ms">> => T,
      <<"last_time_ms">> => Last}.
new(Key, Group) -> #{<<"ev">> => <<"new">>, <<"entity">> => Key, <<"group">> => Group}.
move(Key, From, To) ->
    #{<<"ev">> => <<"move">>, <<"entity">> => Key, <<"from">> => From, <<"to">> => To}.
drop(Key, Group) -> #{<<"ev">> => <<"drop">>, <<"entity">> => Key, <<"group">> => Group}.

intersect(G, Y, W) ->
    #{<<"stage">> => <<"intersect">>, <<"group">> => G, <<"member">> => Y, <<"value">> => W}.

candidate(K, Var, T, Rank) ->
    #{<<"member">> => K, <<"var">> => Var, <<"time_ms">> => T, <<"rank">> => Rank}.

kinematics(G, Method, Candidates, From) ->
    #{<<"stage">> => <<"kinematics">>, <<"group">> => G,
      <<"method">> => atom_to_binary(Method), <<"candidates">> => Candidates,
      <<"winner">> => From}.

attribute(G, Key, Rule, Cands, W, V) ->
    #{<<"stage">> => <<"attribute">>, <<"group">> => G, <<"key">> => Key,
      <<"rule">> => atom_to_binary(Rule),
      <<"candidates">> => [#{<<"member">> => K, <<"value">> => Val,
                             <<"time_ms">> => T, <<"rank">> => RN}
                           || {K, Val, T, _, RN} <- Cands],
      <<"winner">> => W, <<"value">> => V}.
