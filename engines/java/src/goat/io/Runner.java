package goat.io;

import goat.trace.Result;

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
    private Runner() {}

    static final class Usage extends Exception {
        private static final long serialVersionUID = 1L;

        Usage(String m) {
            super(m);
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
        if (!Functions.names().contains(function)) throw new Usage("unknown function " + function);

        long t0 = System.nanoTime();
        List<Object> list = Steps.of(Json.parse(new String(Files.readAllBytes(Paths.get(steps)), StandardCharsets.UTF_8)));
        if (list == null) throw new Usage("steps file has no list steps");
        long t1 = System.nanoTime();

        Path packDir = Paths.get(pack);
        Processor fn;
        try {
            fn = Functions.load(function, packDir);
        } catch (LoadError e) {
            throw new Usage("load_pack: " + e.getMessage());
        }
        long t2 = System.nanoTime();

        int n = list.size();
        Result[] out = new Result[n];
        long ingests = 0, ticks = 0, nEvents = 0, nTrace = 0;
        long t3 = System.nanoTime();
        for (int k = 0; k < n; k++) {
            Map<String, Object> step = (Map<String, Object>) list.get(k);
            if (Steps.isIngest(step)) ingests++;
            else ticks++;
            Result r = Steps.apply(fn, step);
            out[k] = r;
            nEvents += r.events.size();
            nTrace += r.trace.size();
        }
        Map<String, Object> snap = fn.snapshot();
        long t4 = System.nanoTime();

        if (events != null) {
            try (BufferedWriter w = Files.newBufferedWriter(Paths.get(events), StandardCharsets.UTF_8)) {
                for (int k = 0; k < n; k++) {
                    Map<String, Object> line = new LinkedHashMap<>();
                    line.put("step", (long) k);
                    line.put("events", out[k].events);
                    if (trace) line.put("trace", out[k].trace);
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
