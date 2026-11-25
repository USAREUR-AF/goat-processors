# Bringing in a real feed

How to tell whether a sensor feed is ready for the processors, and whether two
feeds will exercise fusion, before either goes into a running pipeline. The
benchmark measures the functions on generated data; this measures a feed.

## The path

| Step | What | Command |
|---|---|---|
| 1 | Record the feed. Set `record.path` and `record.max_mb` in the runner's config ([runner/README.md](../runner/README.md), Record and replay) | `goat-processors config check` |
| 2 | Check the recording | `python3 -I tools/feeds/feedcheck.py RECORD` |
| 3 | Run it through the pipeline offline and look at what came out | `goat-processors replay RECORD -c CONFIG` |
| 4 | When a second feed arrives, check both together | `python3 -I tools/feeds/feedcheck.py A B` |
| 5 | Put the feed into service, watch it ([below](#watching-a-feed-in-service)), and switch its input off to go back | |

Without a feed, `--demo overlap` and `--demo apart` show both fusion outcomes
on generated data.

## What the check says

Each source gets `ready`, `ready, with warnings` or `not ready`, and the
sources together get a fusion verdict.

| Check | Kind | Limit | Why |
|---|---|---|---|
| required keys | required | every report | `track.source_id`, `uid`, `time_ms`, `lat`, `lon`; a report without them is rejected by every function |
| stated error | required | 90 % of reports carry `ce` | without it every report gets the pack's default error, and correlation cannot weigh one source against another |
| error honesty | required | median NIS at most 6 | NIS is the squared distance from the track's prediction over the stated variance; its mean is 2 when the stated error is honest. Understated error is the leading cause of correlation errors in the benchmark ([open work](../reviews/README.md#open-work), item 1) |
| monotonic time | required | 99 % of a track's reports later than the one before | correlate and fuse drop a report that goes back in time |
| velocity | advised | half the reports carry `course` and `speed_ms` | separates crossing and parallel tracks sooner; a passive sensor has none, which is fine |
| receive time | advised | 90 % carry `received_ms` | lets quality measure latency |
| co-observed | fusion | 20 % of a source's track-seconds have another source's track within 2 km | below it the sources rarely see the same objects |
| fused tracks | fusion | 10 % of output tracks hold more than one source | the fusion the pipeline actually performs, with the pack given by `--pack` (default `correlate-assign-time`) |

"Not exercised: the sources rarely see the same objects" means the coverage
does not overlap, and no setting fixes that. "Not exercised although the
sources see the same objects" means correlation keeps them apart: compare the
sources' stated errors and biases, then try another pack with `--pack`.

## Watching a feed in service

The runner's metrics give what to watch.

| Watch | Healthy | If not |
|---|---|---|
| `goat_processors_reports_in_total{source="..."}` | rises at the rate the check measured | the input is not arriving: look upstream of the runner |
| `goat_processors_reports_out_total` against reports in | close to equal | the filter drops the feed: replay the recording with `--trace` and read the filter's records |
| `goat_processors_system_tracks_multi_source` | above 0 once two co-observed sources are in | correlation keeps the sources apart: run the check on a fresh recording |
| restarts of the runner service | none | read the service log, and replay the recording to reproduce |
| quality `action-start` events | rare, each with a reason | the rule names the measure and the source |

To go back, switch the feed's input off and leave the pipeline running; the
other feeds are unaffected. To go forward again: record, check, switch on.

## Sharing results

Never share a recording of a real feed: it holds positions and identifiers.
`feedcheck.py --rename --json` prints counts, rates, shares and medians only,
with the sources renamed s1, s2 and so on. That is what goes into an issue or
a pull request.

## Open work

| # | Work | Done when |
|---|---|---|
| 1 | a scenario family generated from a check's summary (rates, error, detection, latency), so the benchmark measures feeds like the real ones without the data | `dataset.py` takes a summary and the benchmark runs it |
| 2 | estimate a source's position bias against another source in the check | the check reports a bias with an interval, tested on a generated bias |
| 3 | the same numbers over a live window instead of a recording | the runner exposes them on its metrics route |
| 4 | limits measured on the benchmark rather than chosen | each limit cites the benchmark run that set it |
