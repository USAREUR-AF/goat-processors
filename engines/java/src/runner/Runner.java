package runner;

import correlator.Json;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The command-line runner of tools/perf/README.md, "Runner contract":
 * {@code run --function F --pack DIR --steps FILE [--events FILE] [--trace]}.
 */
public final class Runner {

    /** One engine function behind the contract's three calls. */
    interface Function {
        /** Events then trace of one call. */
        List<List<Map<String, Object>>> ingest(Map<String, Object> report);

        List<List<Map<String, Object>>> tick(long now);

        Map<String, Object> snapshot();
    }

    static final class Usage extends Exception {
        private static final long serialVersionUID = 1L;

        Usage(String m) {
            super(m);
        }
    }

    private static Function load(String function, Path pack) throws Exception {
        switch (function) {
            case "correlate": {
                correlator.Engine e = new correlator.Engine(correlator.Engine.loadPack(pack));
                return new Function() {
                    public List<List<Map<String, Object>>> ingest(Map<String, Object> r) {
                        correlator.Engine.Result x = e.ingest(r);
                        return List.of(x.events, x.trace);
                    }
                    public List<List<Map<String, Object>>> tick(long now) {
                        correlator.Engine.Result x = e.tick(now);
                        return List.of(x.events, x.trace);
                    }
                    public Map<String, Object> snapshot() {
                        return e.snapshot();
                    }
                };
            }
            case "filter": {
                filter.Filter e = new filter.Filter(filter.Filter.loadPack(pack));
                return new Function() {
                    public List<List<Map<String, Object>>> ingest(Map<String, Object> r) {
                        correlator.Engine.Result x = e.ingest(r);
                        return List.of(x.events, x.trace);
                    }
                    public List<List<Map<String, Object>>> tick(long now) {
                        correlator.Engine.Result x = e.tick(now);
                        return List.of(x.events, x.trace);
                    }
                    public Map<String, Object> snapshot() {
                        return e.snapshot();
                    }
                };
            }
            case "fuse": {
                fuse.Fuse e = new fuse.Fuse(fuse.Fuse.loadPack(pack));
                return new Function() {
                    public List<List<Map<String, Object>>> ingest(Map<String, Object> r) {
                        fuse.Fuse.Result x = e.ingest(r);
                        return List.of(x.events, x.trace);
                    }
                    public List<List<Map<String, Object>>> tick(long now) {
                        fuse.Fuse.Result x = e.tick(now);
                        return List.of(x.events, x.trace);
                    }
                    public Map<String, Object> snapshot() {
                        return e.snapshot();
                    }
                };
            }
            case "quality": {
                quality.Engine e = new quality.Engine(quality.Engine.loadPack(pack));
                return new Function() {
                    public List<List<Map<String, Object>>> ingest(Map<String, Object> r) {
                        quality.Engine.Result x = e.ingest(r);
                        return List.of(x.events, x.trace);
                    }
                    public List<List<Map<String, Object>>> tick(long now) {
                        quality.Engine.Result x = e.tick(now);
                        return List.of(x.events, x.trace);
                    }
                    public Map<String, Object> snapshot() {
                        return e.snapshot();
                    }
                };
            }
            default:
                throw new Usage("unknown function " + function);
        }
    }

    public static void main(String[] args) {
        try {
            System.exit(run(args));
        } catch (Usage e) {
            System.err.println("run: " + e.getMessage());
            System.exit(2);
        } catch (Exception e) {
            System.err.println("run: " + e);
            System.exit(1);
        }
    }

    @SuppressWarnings("unchecked")
    static int run(String[] args) throws Exception {
        String function = null, pack = null, steps = null, events = null;
        boolean trace = false;
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--function": function = value(args, ++i); break;
                case "--pack": pack = value(args, ++i); break;
                case "--steps": steps = value(args, ++i); break;
                case "--events": events = value(args, ++i); break;
                case "--trace": trace = true; break;
                default: throw new Usage("unknown argument " + args[i]);
            }
        }
        if (function == null || pack == null || steps == null)
            throw new Usage("needs --function, --pack and --steps");
        if (!List.of("correlate", "filter", "fuse", "quality").contains(function))
            throw new Usage("unknown function " + function);

        long t0 = System.nanoTime();
        Object parsed = Json.parse(new String(Files.readAllBytes(Paths.get(steps)), StandardCharsets.UTF_8));
        if (!(parsed instanceof Map) || !(((Map<String, Object>) parsed).get("steps") instanceof List))
            throw new Usage("steps file has no list steps");
        List<Object> list = (List<Object>) ((Map<String, Object>) parsed).get("steps");
        long t1 = System.nanoTime();

        Path packDir = Paths.get(pack);
        Function fn;
        try {
            fn = load(function, packDir);
        } catch (Usage e) {
            throw e;
        } catch (Exception e) {
            throw new Usage("load_pack: " + e.getMessage());
        }
        long t2 = System.nanoTime();

        int n = list.size();
        Object[] out = new Object[n];
        long ingests = 0, ticks = 0, nEvents = 0, nTrace = 0;
        long t3 = System.nanoTime();
        for (int k = 0; k < n; k++) {
            Map<String, Object> step = (Map<String, Object>) list.get(k);
            List<List<Map<String, Object>>> r;
            if (step.containsKey("ingest")) {
                r = fn.ingest((Map<String, Object>) step.get("ingest"));
                ingests++;
            } else {
                r = fn.tick(((Number) step.get("tick")).longValue());
                ticks++;
            }
            out[k] = r;
            nEvents += r.get(0).size();
            nTrace += r.get(1).size();
        }
        Map<String, Object> snap = fn.snapshot();
        long t4 = System.nanoTime();

        if (events != null) {
            try (BufferedWriter w = Files.newBufferedWriter(Paths.get(events), StandardCharsets.UTF_8)) {
                for (int k = 0; k < n; k++) {
                    List<List<Map<String, Object>>> r = (List<List<Map<String, Object>>>) out[k];
                    Map<String, Object> line = new LinkedHashMap<>();
                    line.put("step", (long) k);
                    line.put("events", r.get(0));
                    if (trace) line.put("trace", r.get(1));
                    w.write(Json.write(line));
                    w.write('\n');
                }
                Map<String, Object> last = new LinkedHashMap<>();
                last.put("snapshot", snap);
                w.write(Json.write(last));
                w.write('\n');
            }
        }

        Map<String, Object> c = new LinkedHashMap<>();
        c.put("engine", "java");
        c.put("function", function);
        c.put("pack", packDir.toAbsolutePath().normalize().getFileName().toString());
        c.put("steps", (long) n);
        c.put("ingest", ingests);
        c.put("tick", ticks);
        c.put("events", nEvents);
        c.put("trace_records", nTrace);
        c.put("parse_ns", t1 - t0);
        c.put("load_ns", t2 - t1);
        c.put("run_ns", t4 - t3);
        BufferedWriter so = new BufferedWriter(new OutputStreamWriter(System.out, StandardCharsets.UTF_8));
        so.write(Json.write(c));
        so.write('\n');
        so.flush();
        return 0;
    }

    private static String value(String[] args, int i) throws Usage {
        if (i >= args.length) throw new Usage(args[i - 1] + " needs a value");
        return args[i];
    }
}
