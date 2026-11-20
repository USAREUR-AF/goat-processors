%% Gating measures between an entity's filter and another's prediction
%% (correlate.md "Tests", "Association"): distance and d². Pure.
-module(correlate_gating).
-export([distance/2, d2/3]).

%% Distance between the positions of a filter and a prediction.
distance(#{east := {AE, _, _, _, _}, north := {AN, _, _, _, _}},
         #{east := {BE, _, _, _, _}, north := {BN, _, _, _, _}}) ->
    math:sqrt((AE - BE) * (AE - BE) + (AN - BN) * (AN - BN)).

%% d² = sum over east, north of (pa - pb)² / (pp_b + r_a), r_a A's last
%% report's measurement variance on that axis (ce_a² with time error 0).
d2(#{east := {PAE, _, _, _, _}, north := {PAN, _, _, _, _}}, {RAE, RAN},
   #{east := {PBE, _, PPBE, _, _}, north := {PBN, _, PPBN, _, _}}) ->
    (PAE - PBE) * (PAE - PBE) / (PPBE + RAE) + (PAN - PBN) * (PAN - PBN) / (PPBN + RAN).
