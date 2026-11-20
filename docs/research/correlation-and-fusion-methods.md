# Correlation and fusion methods: survey, prototypes, decisions

Status: Written (survey), Measured (three prototypes), Decided (two ADOPT,
one REJECT). The prototypes are in [tools/research/](../../tools/research/);
every number below comes from `python3 -I tools/research/research.py`.

This page asks one question of each published method: does it fix a
weakness we have measured, at a cost a seven-language specification can
carry? A method is adopted only when it measures better. A method that is
not adopted keeps its row and its reason, so the question is not reopened
without new evidence.

## Contents

1. [Constraints](#constraints)
2. [Where we start](#where-we-start)
3. [Survey](#survey)
4. [Learned methods](#learned-methods)
5. [Shortlist](#shortlist)
6. [How the prototypes are measured](#how-the-prototypes-are-measured)
7. [Prototype 1: measurement-noise scale per source](#prototype-1-measurement-noise-scale-per-source)
8. [Prototype 2: track succession](#prototype-2-track-succession)
9. [Prototype 3: fast covariance intersection](#prototype-3-fast-covariance-intersection)
10. [Decisions](#decisions)
11. [References](#references)

## Constraints

A method must meet all four. One that cannot is out, however well it
scores.

| Constraint | What it rules out |
|---|---|
| The only clock is the time in the input | anything that reads a wall clock, a timer or a time budget |
| Every decision is a trace record (inputs, value, limit, result) | a decision with no single value and limit to record, such as an opaque score |
| Seven independent engines implement it from a written spec | a method whose behavior is defined by a library, a trained model or a solver's internal choices |
| The engines use the standard library only | linear-algebra, optimization or machine-learning packages |

Two more follow from these. Every collection is visited in a stated order,
and floating-point sums are taken in a stated order, so two engines produce
the same bits. And a method's parameters must be derivable from stated
probabilities and physical units, because a pack states the derivation of
every value.

## Where we start

The best method today is `assign` with the pack `correlate-assign-time`:
an exact least-cost assignment per source per tick, a two-model (IMM)
filter per track, a relative position and clock offset per pair of sources,
and a two-tick window with a margin. Its pooled scores
([docs/benchmark.md](../benchmark.md)) are F1 0.997 on the 21 named
scenarios, 0.961 on the 50 random ones and 0.996 on the 7 time scenarios.

Four weaknesses remain. Each was traced to a cause before any method was
chosen.

| Weakness | Measured | Cause found |
|---|---|---|
| Identity swaps on the random set | 33 for assign-time, against 17 to 21 for the confirm packs | 11 of the 16 scenarios with swaps have a sensor that understates its error or reports none. Its tracks leave and rejoin their system tracks |
| Recovery after a track-number drop (`number-drop`) | F1 0.885, time to associate 7.3 s | The old number stays a member until it is stale. A source has at most one member per system track, so the new number cannot join until then |
| `random-17`: three biased sensors | F1 0.620 | The passive sensor (250 m error) reports no error, so the 50 m default stands in. It is a factor of 5 too precise and keeps falling out of its system tracks. The biases are not the cause: with the error corrected (prototype 1) and the same bias estimate, F1 is 0.993 |
| `random-28`: a late sensor that understates its error | F1 0.733 | The passive sensor reports a third of its error. Its tracks flip in and out of their system tracks, and while they are in, the radar's tracks sometimes fall out |

Three of the four weaknesses have one cause: a stated position error that
is too small. That finding shaped the shortlist more than any method's
reputation.

## Survey

Columns: **Problem**, what the method solves; **Targets**, which measured
weakness it addresses (S swaps, D drop, B random-17, U random-28, or none);
**Gain**, the expected effect here; **Cost**, the specification text, the
code per engine (times seven), the run time and memory, and the parameters
an operator must set; **Det.**, whether it keeps determinism and
traceability; **Verdict**.

### Association

| Method | Problem | Targets | Gain | Cost | Det. | Verdict |
|---|---|---|---|---|---|---|
| Global nearest neighbor by exact assignment (today) [Munkres 1957; Jonker and Volgenant 1987; Blackman and Popoli 1999] | one best joint assignment per scan | — | baseline | in place | yes | kept |
| Ranked assignments over a window (today) [Murty 1968] | defer a decision by a few scans | — | baseline | in place | yes | kept |
| JPDA [Fortmann, Bar-Shalom and Scheffe 1983] | soft association of measurements in clutter: each track is updated with a weighted mix of the measurements in its gate | S, slightly | small. Our inputs are tracks from sensors that already did their own association. Soft weights blur which track belongs to which system track, which is the output we must report | joint events grow exponentially with tracks in a cluster; the spec must state the enumeration order of joint events; about 300 lines per engine; detection probability and clutter density to set | yes, with a stated enumeration | not shortlisted |
| Cheap JPDA, suboptimal JPDA, JIPDA [Fitzgerald 1986; Roecker and Phillis 1993; Musicki and Evans 2004] | JPDA at lower cost; JIPDA adds a probability that the target exists | S, slightly | as JPDA. Existence probability is useful for false tracks, but false tracks are not a measured weakness of assign (false merges 9 on the random set) | about 150 to 250 lines per engine; the same parameters plus existence probabilities | yes | not shortlisted |
| Multiple hypothesis tracking, hypothesis- and track-oriented [Reid 1979; Kurien 1990; Blackman 2004] | keep competing association hypotheses until later data decides | S | the ranked-assignment window is already a pruned MHT over 2 ticks. A deeper tree adds output lag or alternatives that overtake on accumulated cost, the two faults that the margin had to correct ([correlate-assign.md](../../spec/correlate-assign.md), Window) | hypothesis trees, pruning and N-scan rules all stated; memory grows with hypotheses; 400 lines or more per engine | yes, with stated pruning | not shortlisted |
| N-scan multi-frame (S-D) assignment [Poore 1994; Deb et al. 1997] | assignment over N scans at once, solved by Lagrangian relaxation | S | as MHT. The relaxation is iterative: its result depends on step sizes and stopping rules, which the spec would have to fix exactly | NP-hard for 3 scans or more; relaxation iteration counts and step rules to state; 500 lines or more per engine | only with fixed iteration rules | not shortlisted |
| PHD and CPHD filters [Mahler 2003; Vo and Ma 2006; Mahler 2007; Vo, Vo and Cantoni 2007] | multi-object filtering without explicit association; estimates the number of objects | none | none for our output. They give no track identities, so they cannot say which reported tracks belong together | Gaussian-mixture pruning and merging rules; clutter, birth and survival models; 400 lines or more per engine | yes, with stated pruning | out: no identities |
| Labeled RFS filters: LMB, GLMB [Vo and Vo 2013; Vo, Vo and Phung 2014; Reuter et al. 2014] | Bayes-optimal multi-object tracking with labels | S, D | possibly fewer swaps, but they are built for detections, not for tracks that sensors have already formed. Each sensor's track number would have to be discarded or modeled | ranked assignment or Gibbs sampling inside every update (a sampler needs a stated generator); birth model; 800 lines or more per engine | yes, with a stated generator | out: cost far above the possible gain |
| PMBM [Williams 2015; García-Fernández et al. 2018] | conjugate multi-object prior for detections; unknown objects as a Poisson part | S, D | as LMB | as LMB | yes, with stated pruning | out: cost far above the possible gain |
| Track-to-track association with the cross-covariance [Bar-Shalom 1981; Bar-Shalom and Campo 1986] | the statistic of two estimates of one object whose errors are correlated by common process noise | S | small in steady flight: the cross term comes from process noise, which with an acceleration variance of 1 m²/s⁴ adds at most q·dt⁴/4 = 64 m² over a 4 s gap, against measurement variances of 225 to 62,500 m². Not small in a maneuver (the second model's 400 m²/s⁴). No measured weakness points to it: the swaps had another cause | a per-pair covariance recursion over asynchronous updates, for both models of the IMM; about 150 lines per engine; no new parameter | yes | PARK |
| Association over a sliding window of common times [Tian and Bar-Shalom 2009] | sum the test statistic of a pair over its last N common times, a chi-square with 2N degrees of freedom | S | some hysteresis against one bad tick. The keep bonus and the two-tick window already give this | per pair, a ring of N statistics in every hypothesis; about 80 lines per engine; N | yes | not shortlisted |
| Sequential likelihood-ratio confirmation [Wald 1947; Sittler 1964] | accumulate the log-likelihood ratio of "same object" against "different objects"; confirm and release at thresholds set by stated error rates | S | measured in correlate 1.0 for the confirm method (pack `correlate-sprt`) | in correlate 1.0 | yes | covered by correlate 1.0 |
| Full-state (position and velocity) statistic [Bar-Shalom 1981] | one chi-square test on the whole kinematic state | S | measured in correlate 1.0 as the `state` test; an option, not a default there | in correlate 1.0 | yes | covered by correlate 1.0 |
| Track-segment association [Yeom, Kirubarajan and Bar-Shalom 2004] | join a track that ended to one that started nearby, predicted across the gap | D | removes the wait for staleness after a number drop | about 20 lines of spec; about 40 lines per engine; one factor | yes | **shortlisted: prototype 2** |

### Fusion

| Method | Problem | Targets | Gain | Cost | Det. | Verdict |
|---|---|---|---|---|---|---|
| Inverse-variance (information) fusion (today) [Maybeck 1979; Chong et al. 2000] | the best combination of independent estimates | — | baseline | in place | yes | kept |
| Information filter | the same estimate in information form; cheap to add measurements | none | none: our fused estimate is already an information sum, recomputed per tick | — | yes | not needed |
| Covariance intersection [Julier and Uhlmann 1997] | a consistent combination when the correlation of the errors is unknown | U | a fused estimate that an over-confident member cannot pull as far. With scalar variances per axis the optimal weight puts everything on the most precise member, so the fast form is the one to test | per axis a weight per member; about 30 lines per engine; no parameter in the fast form | yes | **shortlisted: prototype 3** |
| Fast CI, improved fast CI [Niehsen 2002; Fränken and Hüpper 2005] | closed-form CI weights, no optimization | U | as CI | as CI | yes | tested as prototype 3 |
| Inverse CI [Noack et al. 2017] | a less conservative bound than CI when the estimates share a common part | U | between CI and the information sum | a weight search; about 60 lines per engine | yes, with a stated search | not shortlisted: prototype 3 bounds it |
| Split CI [Julier and Uhlmann 2001; Li, Nashashibi and Yang 2013] | separate the independent and the correlated parts of each covariance | U | needs each sensor to state which part of its error is shared. Our reports state one error | per-member split covariances; reports must carry the split | yes | out: our inputs lack the split |
| Ellipsoidal intersection [Sijs and Lazar 2012] | fuse with an explicit estimate of the shared part | U | as inverse CI; the 1-D form per axis reduces to a closed form | about 50 lines per engine | yes | not shortlisted: prototype 3 bounds it |
| Track-to-track fusion with known correlation [Bar-Shalom and Campo 1986] | optimal fusion when the cross-covariance is known | none | as the cross-covariance under Association: small in steady flight, larger in a maneuver | per-pair recursion | yes | PARK |

### Filtering

| Method | Problem | Targets | Gain | Cost | Det. | Verdict |
|---|---|---|---|---|---|---|
| Constant velocity and IMM (today) [Blom and Bar-Shalom 1988; Bar-Shalom, Li and Kirubarajan 2001] | maneuvering targets with a linear model | — | baseline | in place | yes | kept |
| Unscented filter [Julier and Uhlmann 1997, 2004] | nonlinear measurement or motion models without Jacobians | none | none: our measurements are positions in a local plane, so the update is linear | sigma-point rules; matrix square roots (Cholesky) stated exactly; about 150 lines per engine | yes | out: no nonlinearity to handle |
| Cubature filter [Arasaratnam and Haykin 2009] | as the unscented filter, with a fixed cubature rule | none | none, as above | as above | yes | out |
| Singer acceleration model [Singer 1970] | correlated acceleration as a third state | none | the IMM already covers the turns in the benchmark: turn-6dps F1 is 1.000 with assign-time | a third state per axis; every filter formula changes; one time constant | yes | not shortlisted |
| Constant-turn model [Li and Jilkov 2003] | coordinated turns | none | as Singer; it also couples the two axes, which today run independently | a coupled 4- or 5-state filter; the spec's per-axis structure changes | yes | not shortlisted |
| Out-of-sequence measurement update [Bar-Shalom 2002; Bar-Shalom, Chen and Mallick 2004] | use a report older than the track's last update instead of rejecting it | none | the out-of-order scenario already scores F1 1.000 with assign-time; rejection costs one report in a stream of many | per entity, the retrodiction quantities; about 60 lines per engine | yes | not shortlisted |
| Adaptive measurement noise by covariance matching [Mehra 1970, 1972; Myers and Tapley 1976; Särkkä and Nummenmaa 2009] | estimate the true measurement variance from the filter's own innovations | S, B, U | corrects the cause of three of the four weaknesses | about 25 lines of spec; about 40 lines per engine; a prior weight and a ceiling | yes | **shortlisted: prototype 1** |

### Registration and time

| Method | Problem | Targets | Gain | Cost | Det. | Verdict |
|---|---|---|---|---|---|---|
| Relative position offset per pair of sources (today) [Dana 1990; Helmick and Rice 1993] | translational sensor bias | — | baseline | in place | yes | kept |
| Clock offset per pair, fitted with the position offset (today) [Li, Leung and Zhou 2004] | a sensor whose clock is off | — | baseline | in place | yes | kept |
| Joint bias estimation over all sources [Okello and Ristic 2003; Lin, Bar-Shalom and Kirubarajan 2004] | one consistent bias per sensor instead of one per pair | B | small: with prototype 1, random-17 reaches F1 0.991 with the per-pair estimate. The remaining position error in the biased scenarios is absolute bias, which no relative method can observe (below) | a linear system per axis, size the number of sources; a reference sensor or a sum constraint | yes | not shortlisted |
| Joint association, registration and fusion by EM [Li et al. 2010] | estimate biases and associations together, iterating to convergence | B | as above; adds iteration counts and stopping rules to the spec | iterative; stopping rules to state | only with fixed iterations | not shortlisted |

**A limit, not a gap.** In `random-34` the beacon carries a 320 m bias and
the radar none. Association is nearly perfect (F1 0.998 with assign-time), but the position error
RMS is 313 m, because the fused estimate leans on the precise, biased
beacon. Relative registration can only say that the two sensors disagree by
320 m; it cannot say which is right. Only a reference (a sensor declared
unbiased, or known landmarks) makes absolute bias observable. That is a
pack-level choice, not a new method.

## Learned methods

Graph neural networks [Brasó and Leal-Taixé 2020] and transformers
[Meinhardt et al. 2022; Zeng et al. 2022] are the current best methods for
multi-object tracking in video. They are out for the engines. A trained
model is a large table of weights whose behavior is not written in a
specification; seven independent engines could implement it only by
copying the weights and the exact order of every floating-point operation,
which is porting, not implementing a spec. Their decisions are not single
tests with a value and a limit, so the trace would record a score without
a reason. They need numerical libraries the engines may not use. They are
trained on detections in images, not on tracks from sensors that already
did their own association, and we have no labeled data of our own to train
on. One narrow use stays deterministic: fitting a pack's parameters offline
(for example, a gate or a prior) against the benchmark, and writing the
fitted value into the pack with its derivation. That is ordinary parameter
fitting and needs no learned model in the engines.

## Shortlist

| # | Method | Targets | Why it passed |
|---|---|---|---|
| 1 | Measurement-noise scale per source (covariance matching) | swaps, random-17, random-28 | it addresses the measured cause of three weaknesses, in about 25 lines of spec |
| 2 | Track succession (track-segment association) | number-drop | it addresses the measured cause, in about 20 lines of spec |
| 3 | Fast covariance intersection for the fused estimate | random-28 | it is the cheapest modern fusion rule, and it tests whether the fusion rule rather than the noise is at fault |

## How the prototypes are measured

| Item | How |
|---|---|
| Prototype | a subclass of the Python reference engine in [tools/research/variants.py](../../tools/research/variants.py); the engine is not changed |
| Base pack | `correlate-assign-time` |
| Scenarios | the 78 benchmark scenarios of [tools/bench](../../tools/bench/), scored by its `score.py`, pooled by set as in [docs/benchmark.md](../benchmark.md) |
| Held-out set | 50 more random scenarios from seed 20261120, built by the same generator. No parameter was chosen on them |
| Baselines | main, and the correlate 1.0 branch (`fn/correlate`), where per-source staleness already shortens the wait after a drop |
| Run-to-run noise | 0. The engines are deterministic: two runs give the same bits, and the harness reproduces every committed benchmark score of the base pack exactly |
| Scenario noise | the difference a different draw of scenarios would make: a paired bootstrap over the scenarios of each set, 1,000 draws, 95 % interval. A difference is "beyond noise" when that interval excludes 0 |
| Parameters | set before the first run and not changed. The alternatives tried are reported |
| Run time | the tools/perf large scenario (18,571 reports, 12 objects, 600 s), engine calls only, median of 3 |

## Prototype 1: measurement-noise scale per source

**Method.** For each source keep a running sum over its reports. On each
report of a track that already has a filter, before the update, take the
innovation `y = z - p` on each axis, where `p` and `pp` are the filter's
prediction to the report's time and `r0` the stated variance (`ce²` plus
the timing variance). Then `y²` has expectation `pp + R_true`, so

`lambda = (nu0 + sum((y² - pp) / r0)) / (nu0 + n)`,

with `n` the number of axis samples and `nu0` the weight of a prior
`lambda = 1`, estimates `R_true / r0`. Each later report of the source uses
`ce * sqrt(lambda)` in place of its `ce`, with `lambda` clamped to
`[1, 25]`. This is the covariance-matching estimate [Mehra 1972; Myers and
Tapley 1976] with a conjugate prior on a variance scale [Särkkä and
Nummenmaa 2009].

| Property | Value |
|---|---|
| Parameters | `nu0 = 10` (a prior worth five reports on two axes); ceiling 25 (an error understated by up to 5 times) |
| Alternative tried | `nu0 = 30`: random F1 0.986, held-out swaps 17 (against 15), time-set RMS 38.9 m; the result does not hinge on the prior |
| Why the floor is 1 | a scale below 1 trusts a sensor more than it claims. Measured: allowing it (floor 0.04) lowers named F1 0.997 to 0.944 and raises random swaps 33 to 87 |
| What it does not see | a constant bias (the filter follows it) and a constant clock offset (it moves every report alike). Reports that fail the restart test are left out, so a moved track number does not count as noise |
| State | two numbers per source |
| Trace | one record per report: `noise_scale`, value `lambda` |

**Results against main** (base `correlate-assign-time`; `*` beyond noise):

| Set | Measure | Base | Prototype 1 | 95 % interval of the difference |
|---|---|---|---|---|
| random | F1 | 0.961 | 0.986* | +0.006 to +0.052 |
| random | identity swaps | 33 | 29 | -12 to +3 |
| random | time to associate, s | 0.84 | 0.67* | -0.37 to -0.04 |
| random | GOSPA, m | 244.0 | 217.0* | -52.2 to -6.4 |
| held-out | F1 | 0.958 | 0.984* | +0.005 to +0.057 |
| held-out | identity swaps | 41 | 15* | -58 to -3 |
| held-out | GOSPA, m | 238.3 | 216.7* | -46.0 to -3.9 |
| named | every measure | 0.997 F1 | unchanged (RMS -0.04 m, noise) | |
| time | position RMS, m | 38.6 | 39.1 | -0.02 to +1.23 (noise) |

| Named weakness | Base | Prototype 1 |
|---|---|---|
| random-17 F1 | 0.620 | 0.993 |
| random-28 F1 | 0.733 | 0.969 |

The time-set RMS change comes from one scenario,
`clock-free-running-undescribed` (116.7 to 118.6 m). The undescribed clock
error enters that source's innovations during turns, so its scale rises
and it is weighted a little less.

**The confirm method.** The same prototype on `correlate-gnn-imm` makes
random missed merges 55 to 79 and random RMS 534 to 1,480 m. The cause
was not traced further. Correlate 1.0 replaces the confirm defaults, and
prototype 1 is proposed for the assign method only.

## Prototype 2: track succession

**Method.** A member of a system track is *overdue* when it has not
reported for more than `factor` times its source's median update interval
(the lower median of the source's last 9 intervals, as correlate 1.0's
`stale_rate`). When a source's tracks are assigned, a system track whose
only member from that source is overdue is still a column for that source,
scored on its other members. A new track that joins it takes the overdue
member's place: the overdue member leaves, reason `succeeded`. An overdue
member that nobody replaces stays until its ordinary staleness. This is
track-segment association [Yeom, Kirubarajan and Bar-Shalom 2004] in the
one case where the other sensors still hold the object, so no prediction
across a gap is needed.

| Property | Value |
|---|---|
| Parameter | `factor = 2.5`: overdue after two missed updates in a row. A live track at a detection probability of 0.9 misses two given updates in a row with probability 0.01, and even then it is replaced only by a new number of the same source that passes the gate |
| Alternatives tried | on main: 2.0 raises held-out false merges 5 to 7; 3.0 gives the same number-drop result with a little less pooled gain (random time to associate 0.37 s against 0.35 s); 4.0 leaves number-drop at 1.3 s |
| State | the update intervals per source, shared with `stale_rate` |
| Trace | the existing assignment records; one `leave` event, reason `succeeded` |

**Results** (`*` beyond noise):

| Set | Measure | main | + prototype 2 | correlate 1.0 | + prototype 2 |
|---|---|---|---|---|---|
| random | F1 | 0.961 | 0.965* | 0.962 | 0.963* |
| random | identity swaps | 33 | 25* | 28 | 26 |
| random | time to associate, s | 0.84 | 0.35* | 0.46 | 0.38* |
| random | GOSPA, m | 244.0 | 234.8* | 234 | 232* |
| held-out | identity swaps | 41 | 34* | 36 | 35 |
| held-out | time to associate, s | 0.96 | 0.62* | 0.55 | 0.65 (noise) |
| number-drop | F1 | 0.885 | 0.975 | 0.939 | 0.970 |
| number-drop | time to associate, s | 7.3 | 0.0 | 2.3 | 0.0 |

Correlate 1.0's per-source staleness already recovers most of the drop
(7.3 to 2.3 s). Succession removes the rest, and with prototype 1 it adds
gains beyond noise on top of it (next section).

## Prototype 3: fast covariance intersection

**Method.** The fused estimate of a system track, per axis, with weights
`w_i = (1/pp_i) / sum(1/pp_j)`: `P = 1 / sum(w_i / pp_i)`,
`x = P * sum(w_i * x_i / pp_i)`; the same for velocity with `vv`. Tested in
the cost and the output, and in the output only.

**Results against main** (`*` beyond noise, `!` worse beyond noise):

| Set | Measure | Base | Fast CI, cost and output | Fast CI, output only |
|---|---|---|---|---|
| time | position RMS, m | 38.6 | 25.2 | 25.2 |
| time | GOSPA, m | 25.9 | 19.0* | 20.6 |
| random | position RMS, m | 87.1 | 87.6 | 88.2 |
| held-out | position RMS, m | 122.3 | 127.0! | 127.3! |
| held-out | identity swaps | 41 | 34* | 41 |
| random-28 | F1 | 0.733 | 0.683 | 0.733 |

It helps where a member's clock is wrong (time set; the largest gain is
`clock-free-running-undescribed`, 116.7 to 66.4 m), and costs accuracy
where the members' errors are independent, which is the common case. A
pooled measure gets worse beyond noise.

## Decisions

### Combined, on correlate 1.0

ADOPT decisions take effect after correlate 1.0, so the decision baseline
is the 1.0 branch. Base `correlate-assign-time` 1.0.0 (`*` beyond noise):

| Set | Measure | 1.0 | + prototype 1 | + prototypes 1 and 2 |
|---|---|---|---|---|
| named | F1 | 0.998 | 0.998 | 0.999 |
| named | false merges / missed merges / swaps | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| named | time to associate, s | 0.11 | 0.11 | 0.00 |
| named | position RMS, m | 11.36 | 11.32 | 11.32 |
| named | GOSPA, m | 39.2 | 39.1 | 38.2 |
| random | F1 | 0.962 | 0.987* | 0.988* |
| random | false merges / missed merges | 9 / 2 | 8 / 0 | 8 / 0 |
| random | identity swaps | 28 | 27 | 25 |
| random | time to associate, s | 0.46 | 0.33* | 0.22* |
| random | position RMS, m | 86.97 | 86.41 | 86.37 |
| random | GOSPA, m | 234.2 | 206.8* | 203.6* |
| time | F1 | 0.996 | 0.996 | 0.996 |
| time | false merges / missed merges / swaps | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| time | position RMS, m | 38.56 | 39.08 (noise) | 39.08 (noise) |
| time | GOSPA, m | 25.92 | 26.05 (noise) | 26.05 (noise) |
| held-out | F1 | 0.959 | 0.985* | 0.986* |
| held-out | false merges / missed merges | 5 / 6 | 1 / 1 | 1 / 1 |
| held-out | identity swaps | 36 | 13* | 12* |
| held-out | time to associate, s | 0.55 | 0.44 | 0.39 |
| held-out | position RMS, m | 121.7 | 118.7 | 118.6 |
| held-out | GOSPA, m | 233.8 | 212.1* | 210.9* |
| number-drop | F1 | 0.939 | 0.939 | 0.970 |
| number-drop | time to associate, s | 2.3 | 2.3 | 0.0 |
| random-17 | F1 | 0.620 | 0.991 | 0.991 |
| random-28 | F1 | 0.733 | 0.969 | 0.969 |

Prototype 2 against prototype 1 alone, on 1.0: random F1, time to
associate, RMS and GOSPA, and held-out GOSPA, all better beyond noise; no
pooled measure worse. Prototype 2 alone on 1.0 moves held-out time to
associate from 0.55 to 0.65 s (within noise), so it is adopted with
prototype 1, not before it.

**The one point estimate that moves the wrong way** is time-set position
RMS, +0.52 m (95 % interval -0.02 to +1.23 m, so within noise), all from
`clock-free-running-undescribed` (prototype 1, above). There a clock that
is 1.5 s off and not described looks like noise to the filter, so the
scale weights that source less. Whether a change within noise counts
against the rule "no pooled measure gets worse" is proc-coord's call.

Run time, Python engine on correlate 1.0, the tools/perf large scenario
(18,571 reports), engine calls only. Three repeats, interleaved across the
variants because the machine was shared (load average 36 to 98 during the
run). Ratio: the median of the per-repeat ratios to the base.

| Variant | Median, s | Reports per second | Range, s | Ratio to base |
|---|---|---|---|---|
| 1.0 `correlate-assign-time` | 195.0 | 95 | 184.1 to 199.1 | 1.00 |
| + prototype 1 | 133.4 | 139 | 128.9 to 169.8 | 0.67 |
| + prototype 2 | 204.4 | 91 | 195.0 to 260.7 | 1.11 |
| + prototypes 1 and 2 | 131.3 | 141 | 113.6 to 145.1 | 0.71 |

Prototype 1 makes the assign method faster. Tracks that no longer flip
in and out of their system tracks leave fewer near-tie alternatives in the
window. Prototype 2 alone costs about a tenth: the overdue check runs per
column per source. Together they are faster than the base. Memory: two
numbers per source (prototype 1) and the interval ring that `stale_rate`
already keeps (prototype 2).

### Verdicts

| Method | Verdict | Evidence | Condition |
|---|---|---|---|
| Measurement-noise scale per source | **ADOPT** for the assign method | random-17 0.620 to 0.991, random-28 0.733 to 0.969; random and held-out F1 and GOSPA better beyond noise; held-out swaps 36 to 13; run time 0.67 of the base | an option first (`noise_scale nu0= ceiling=`), default in the assign packs that carry `bias`. Not for the confirm method (measured worse) |
| Track succession | **ADOPT** for the assign method, after `stale_rate`, with the noise scale | number-drop 2.3 to 0 s on 1.0; random time to associate and GOSPA better beyond noise; run time with both 0.71 of the base | an option (`succession factor=`), using `stale_rate`'s interval state |
| Fast covariance intersection | **REJECT** for the correlate output | held-out RMS 122 to 127 m, worse beyond noise; random-28 0.733 to 0.683 in the cost | fuse keeps covariance intersection where errors may be shared, as it specifies today |
| Cross-covariance in association and fusion | **PARK** | the process-noise term is at most 64 m² in steady flight against 225 to 62,500 m²; no measured weakness points to it | revisit with a scenario of two sensors on one maneuvering object that fails on the association statistic |
| JPDA and fast variants, MHT, N-scan assignment | **PARK** | the two-tick ranked window is already a pruned MHT; the measured swaps had a different cause | revisit if swaps remain after prototype 1 on a new scenario family |
| PHD, CPHD, LMB, GLMB, PMBM | **REJECT** for the engines | no identities (PHD, CPHD); cost far above the gain for sensor tracks (labeled filters) | |
| Unscented and cubature filters | **REJECT** | the measurement model is linear | |
| Singer, constant-turn, out-of-sequence update | **PARK** | no measured weakness; turn-6dps and out-of-order already score 1.000 | revisit with a scenario that fails on them |
| Joint bias estimation, EM registration | **PARK** | random-17 is solved by prototype 1; absolute bias is unobservable without a reference | |
| Learned methods | **REJECT** for the engines | Learned methods, above | offline parameter fitting stays allowed |

### Hand-over

| To | What |
|---|---|
| proc-correlate | prototype 1 and 2 as spec rounds of `correlate-assign.md` after correlate 1.0; the prototype code in [tools/research/variants.py](../../tools/research/variants.py) as evidence. Vectors to separate: a source whose scale reaches the ceiling; a source whose estimate would fall below 1; a restarted report left out of the sum; an overdue member replaced; an overdue member not replaced, then stale |
| proc-coord | sequencing; each method is one spec round with its own vectors and seven engines |

## References

- Arasaratnam, I., and Haykin, S. (2009). Cubature Kalman filters. *IEEE Transactions on Automatic Control*, 54(6), 1254-1269.
- Bar-Shalom, Y. (1981). On the track-to-track correlation problem. *IEEE Transactions on Automatic Control*, 26(2), 571-572.
- Bar-Shalom, Y. (2002). Update with out-of-sequence measurements in tracking: exact solution. *IEEE Transactions on Aerospace and Electronic Systems*, 38(3), 769-777.
- Bar-Shalom, Y., and Campo, L. (1986). The effect of the common process noise on the two-sensor fused-track covariance. *IEEE Transactions on Aerospace and Electronic Systems*, 22(6), 803-805.
- Bar-Shalom, Y., Chen, H., and Mallick, M. (2004). One-step solution for the multistep out-of-sequence-measurement problem in tracking. *IEEE Transactions on Aerospace and Electronic Systems*, 40(1), 27-37.
- Bar-Shalom, Y., Li, X. R., and Kirubarajan, T. (2001). *Estimation with Applications to Tracking and Navigation*. Wiley.
- Blackman, S. S. (2004). Multiple hypothesis tracking for multiple target tracking. *IEEE Aerospace and Electronic Systems Magazine*, 19(1), 5-18.
- Blackman, S. S., and Popoli, R. (1999). *Design and Analysis of Modern Tracking Systems*. Artech House.
- Blom, H. A. P., and Bar-Shalom, Y. (1988). The interacting multiple model algorithm for systems with Markovian switching coefficients. *IEEE Transactions on Automatic Control*, 33(8), 780-783.
- Brasó, G., and Leal-Taixé, L. (2020). Learning a neural solver for multiple object tracking. *IEEE/CVF Conference on Computer Vision and Pattern Recognition*.
- Chong, C.-Y., Mori, S., Barker, W. H., and Chang, K.-C. (2000). Architectures and algorithms for track association and fusion. *IEEE Aerospace and Electronic Systems Magazine*, 15(1), 5-13.
- Dana, M. P. (1990). Registration: a prerequisite for multiple sensor tracking. In Y. Bar-Shalom (Ed.), *Multitarget-Multisensor Tracking: Advanced Applications*. Artech House.
- Deb, S., Yeddanapudi, M., Pattipati, K., and Bar-Shalom, Y. (1997). A generalized S-D assignment algorithm for multisensor-multitarget state estimation. *IEEE Transactions on Aerospace and Electronic Systems*, 33(2), 523-538.
- Fitzgerald, R. J. (1986). Development of practical PDA logic for multitarget tracking by microprocessor. *American Control Conference*.
- Fortmann, T. E., Bar-Shalom, Y., and Scheffe, M. (1983). Sonar tracking of multiple targets using joint probabilistic data association. *IEEE Journal of Oceanic Engineering*, 8(3), 173-184.
- Fränken, D., and Hüpper, A. (2005). Improved fast covariance intersection for distributed data fusion. *International Conference on Information Fusion*.
- García-Fernández, Á. F., Williams, J. L., Granström, K., and Svensson, L. (2018). Poisson multi-Bernoulli mixture filter: direct derivation and implementation. *IEEE Transactions on Aerospace and Electronic Systems*, 54(4), 1883-1901.
- Helmick, R. E., and Rice, T. R. (1993). Removal of alignment errors in an integrated system of two 3-D sensors. *IEEE Transactions on Aerospace and Electronic Systems*, 29(4), 1333-1343.
- Jonker, R., and Volgenant, A. (1987). A shortest augmenting path algorithm for dense and sparse linear assignment problems. *Computing*, 38(4), 325-340.
- Julier, S. J., and Uhlmann, J. K. (1997). A new extension of the Kalman filter to nonlinear systems. *Proc. SPIE 3068, Signal Processing, Sensor Fusion, and Target Recognition VI*.
- Julier, S. J., and Uhlmann, J. K. (1997). A non-divergent estimation algorithm in the presence of unknown correlations. *American Control Conference*.
- Julier, S. J., and Uhlmann, J. K. (2001). General decentralized data fusion with covariance intersection. In D. L. Hall and J. Llinas (Eds.), *Handbook of Multisensor Data Fusion*. CRC Press.
- Julier, S. J., and Uhlmann, J. K. (2004). Unscented filtering and nonlinear estimation. *Proceedings of the IEEE*, 92(3), 401-422.
- Kurien, T. (1990). Issues in the design of practical multitarget tracking algorithms. In Y. Bar-Shalom (Ed.), *Multitarget-Multisensor Tracking: Advanced Applications*. Artech House.
- Li, H., Nashashibi, F., and Yang, M. (2013). Split covariance intersection filter: theory and its application to vehicle localization. *IEEE Transactions on Intelligent Transportation Systems*, 14(4), 1860-1871.
- Li, W., Leung, H., and Zhou, Y. (2004). Space-time registration of radar and ESM using unscented Kalman filter. *IEEE Transactions on Aerospace and Electronic Systems*, 40(3), 824-836.
- Li, X. R., and Jilkov, V. P. (2003). Survey of maneuvering target tracking. Part I: Dynamic models. *IEEE Transactions on Aerospace and Electronic Systems*, 39(4), 1333-1364.
- Li, Z., Chen, S., Leung, H., and Bossé, É. (2010). Joint data association, registration, and fusion using EM-KF. *IEEE Transactions on Aerospace and Electronic Systems*, 46(2), 496-507.
- Lin, X., Bar-Shalom, Y., and Kirubarajan, T. (2004). Exact multisensor dynamic bias estimation with local tracks. *IEEE Transactions on Aerospace and Electronic Systems*, 40(2), 576-590.
- Mahler, R. P. S. (2003). Multitarget Bayes filtering via first-order multitarget moments. *IEEE Transactions on Aerospace and Electronic Systems*, 39(4), 1152-1178.
- Mahler, R. P. S. (2007). PHD filters of higher order in target number. *IEEE Transactions on Aerospace and Electronic Systems*, 43(4), 1523-1543.
- Maybeck, P. S. (1979). *Stochastic Models, Estimation, and Control*, Vol. 1. Academic Press.
- Mehra, R. K. (1970). On the identification of variances and adaptive Kalman filtering. *IEEE Transactions on Automatic Control*, 15(2), 175-184.
- Mehra, R. K. (1972). Approaches to adaptive filtering. *IEEE Transactions on Automatic Control*, 17(5), 693-698.
- Meinhardt, T., Kirillov, A., Leal-Taixé, L., and Feichtenhofer, C. (2022). TrackFormer: multi-object tracking with transformers. *IEEE/CVF Conference on Computer Vision and Pattern Recognition*.
- Munkres, J. (1957). Algorithms for the assignment and transportation problems. *Journal of the Society for Industrial and Applied Mathematics*, 5(1), 32-38.
- Murty, K. G. (1968). An algorithm for ranking all the assignments in order of increasing cost. *Operations Research*, 16(3), 682-687.
- Musicki, D., and Evans, R. (2004). Joint integrated probabilistic data association: JIPDA. *IEEE Transactions on Aerospace and Electronic Systems*, 40(3), 1093-1099.
- Myers, K. A., and Tapley, B. D. (1976). Adaptive sequential estimation with unknown noise statistics. *IEEE Transactions on Automatic Control*, 21(4), 520-523.
- Niehsen, W. (2002). Information fusion based on fast covariance intersection filtering. *International Conference on Information Fusion*.
- Noack, B., Sijs, J., Reinhardt, M., and Hanebeck, U. D. (2017). Decentralized data fusion with inverse covariance intersection. *Automatica*, 79, 35-41.
- Okello, N. N., and Ristic, B. (2003). Maximum likelihood registration for multiple dissimilar sensors. *IEEE Transactions on Aerospace and Electronic Systems*, 39(3), 1074-1083.
- Poore, A. B. (1994). Multidimensional assignment formulation of data association problems arising from multitarget and multisensor tracking. *Computational Optimization and Applications*, 3(1), 27-57.
- Reid, D. B. (1979). An algorithm for tracking multiple targets. *IEEE Transactions on Automatic Control*, 24(6), 843-854.
- Reuter, S., Vo, B.-T., Vo, B.-N., and Dietmayer, K. (2014). The labeled multi-Bernoulli filter. *IEEE Transactions on Signal Processing*, 62(12), 3246-3260.
- Roecker, J. A., and Phillis, G. L. (1993). Suboptimal joint probabilistic data association. *IEEE Transactions on Aerospace and Electronic Systems*, 29(2), 510-517.
- Särkkä, S., and Nummenmaa, A. (2009). Recursive noise adaptive Kalman filtering by variational Bayesian approximations. *IEEE Transactions on Automatic Control*, 54(3), 596-600.
- Sijs, J., and Lazar, M. (2012). State fusion with unknown correlation: ellipsoidal intersection. *Automatica*, 48(8), 1874-1878.
- Singer, R. A. (1970). Estimating optimal tracking filter performance for manned maneuvering targets. *IEEE Transactions on Aerospace and Electronic Systems*, 6(4), 473-483.
- Sittler, R. W. (1964). An optimal data association problem in surveillance theory. *IEEE Transactions on Military Electronics*, 8(2), 125-139.
- Tian, X., and Bar-Shalom, Y. (2009). Track-to-track fusion configurations and association in a sliding window. *Journal of Advances in Information Fusion*, 4(2), 146-164.
- Vo, B.-N., and Ma, W.-K. (2006). The Gaussian mixture probability hypothesis density filter. *IEEE Transactions on Signal Processing*, 54(11), 4091-4104.
- Vo, B.-T., and Vo, B.-N. (2013). Labeled random finite sets and multi-object conjugate priors. *IEEE Transactions on Signal Processing*, 61(13), 3460-3475.
- Vo, B.-N., Vo, B.-T., and Phung, D. (2014). Labeled random finite sets and the Bayes multi-target tracking filter. *IEEE Transactions on Signal Processing*, 62(24), 6554-6567.
- Vo, B.-T., Vo, B.-N., and Cantoni, A. (2007). Analytic implementations of the cardinalized probability hypothesis density filter. *IEEE Transactions on Signal Processing*, 55(7), 3553-3567.
- Wald, A. (1947). *Sequential Analysis*. Wiley.
- Williams, J. L. (2015). Marginal multi-Bernoulli filters: RFS derivation of MHT, JIPDA, and association-based MeMBer. *IEEE Transactions on Aerospace and Electronic Systems*, 51(3), 1664-1687.
- Yeom, S.-W., Kirubarajan, T., and Bar-Shalom, Y. (2004). Track segment association, fine-step IMM and initialization with Doppler for improved track performance. *IEEE Transactions on Aerospace and Electronic Systems*, 40(1), 293-309.
- Zeng, F., Dong, B., Zhang, Y., Wang, T., Zhang, X., and Wei, Y. (2022). MOTR: end-to-end multiple-object tracking with transformer. *European Conference on Computer Vision*.
