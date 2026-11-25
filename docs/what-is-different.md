# What is different about goat's track processing

The processing works on one shared model of every sensor's reports, carries the
quality of each sensor's clock with every report, and explains every decision
it makes.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="explainers/what-goat-adds-dark.svg">
  <img alt="Sensor formats such as CoT, ASTERIX, NMEA 2000, ADS-B, Remote ID, MAVLink 2 and SAPIENT feed goat-transformers, which writes one model in fixed units including time error. Each report then carries its clock's error and state: plus or minus 2 ms coherent, 80 ms drifting or 400 ms free-running, with a wider position region the looser the clock. goat-processors runs filter, correlate, fuse and quality without reading a clock, set by a pack of settings, and publishes system tracks on the Zenoh fabric with a record of why each decision was made." src="explainers/what-goat-adds-light.svg">
</picture>

1. **One shared model.** [goat-transformers](https://github.com/USAREUR-AF/goat-transformers)
   translates messages from thousands of formats, such as Cursor on Target,
   ASTERIX, NMEA 2000, ADS-B, Remote ID, MAVLink 2, SAPIENT and GeoJSON, into
   one shared model: typed keys in fixed units (degrees, meters,
   milliseconds). goat-processors reads only that model, so a new sensor format
   needs a format file in goat-transformers and no change to the processing.
   Each format is a data file, not code; seven engines read it and must agree
   byte for byte.
2. **Clock quality travels with every report.** goat nodes keep time among
   themselves first and use satellite or network time as an anchor when it is
   available; agreeing with each other and knowing UTC are two separate facts.
   A report can carry `time_error_ms`, the bound on how far its time may be
   from the time the nodes share, and `time_state`: coherent, drifting or
   free-running ([correlate.md, Time quality](../spec/correlate.md#time-quality)).
   The correlator turns clock error into position uncertainty (speed × time
   error), so a fast target from a loose clock gets a wider region instead of a
   wrong match. The default pack also fits a clock offset between each pair of
   sensors, and the [quality](../spec/quality.md) function measures late
   reports, reports out of order, and sources whose time runs behind or ahead
   of the others, and can act on them.
3. **The processing never reads a clock.** Its only time is the time in the
   reports, so a recording replayed later gives exactly the same decisions. The
   runner can record its input and replay it
   ([runner/README.md](../runner/README.md)).
4. **Behavior is set by packs.** Each function (filter, correlate, fuse,
   quality) is a written specification in [spec/](../spec/). A pack is a plain
   settings file with no code, for example which tests run and their limits,
   so a mission changes behavior by choosing a pack. Test cases (vectors) state
   the exact output, and seven independently written engines (Python, Rust,
   Go, Java, C++, Erlang, Zig) reproduce every vector exactly.
5. **Every decision is explained.** Each engine emits a trace record for every
   test it runs: what it compared, the value, the limit and the result. An
   operator can see why two tracks were or were not joined.
6. **Runs on the goat data fabric.** The runner subscribes to translated
   reports on Zenoh and publishes system tracks as droppable live data, so a
   slow consumer never holds up the picture. Each node can run its own
   processing, with no central server.
7. **Measured in the open.** Every correlate pack is scored against ground
   truth on public scenarios and on a held-out set that no pack is tuned on,
   beside an outside tracker built on Stone Soup, the open tracking framework
   of the UK Defence Science and Technology Laboratory
   ([docs/benchmark.md](benchmark.md)). Anyone can rerun the scoring and submit
   an improvement with its measured result
   ([contribute](https://usareur-af.github.io/goat-processors/contribute.html)).

How the correlator itself decides: [how-correlation-works.md](how-correlation-works.md).
