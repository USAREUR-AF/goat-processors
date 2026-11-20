package goat.coverage;

import com.sun.jdi.AbsentInformationException;
import com.sun.jdi.Bootstrap;
import com.sun.jdi.Location;
import com.sun.jdi.ReferenceType;
import com.sun.jdi.VirtualMachine;
import com.sun.jdi.connect.Connector;
import com.sun.jdi.connect.LaunchingConnector;
import com.sun.jdi.event.BreakpointEvent;
import com.sun.jdi.event.ClassPrepareEvent;
import com.sun.jdi.event.Event;
import com.sun.jdi.event.EventSet;
import com.sun.jdi.event.VMDisconnectEvent;
import com.sun.jdi.request.BreakpointRequest;
import com.sun.jdi.request.ClassPrepareRequest;
import com.sun.jdi.request.EventRequest;
import com.sun.jdi.request.EventRequestManager;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.stream.Stream;

/**
 * Line coverage with the JDK's own debugger interface (module jdk.jdi), no third-party package.
 *
 * <p>{@code Coverage <classpath> <classes dir> <report file> <floor percent> <jvm options> <command>...}:
 * runs each command (a main class and its arguments, one string) in a VM it launches, with a
 * breakpoint on every line of every class of the classes directory; a line is covered when one
 * of its breakpoints is hit in any command (then its breakpoints are removed). The lines are the
 * classes' line tables: the lines that hold code. A first command loads every class
 * ({@link LoadAll}), so a class no command touches still counts its lines. Writes a per-file
 * report, prints the total, and exits 1 when the total is below the floor.
 */
public final class Coverage {
    private Coverage() {}

    /** source path -> line -> covered */
    private final Map<String, Map<Integer, Boolean>> lines = new TreeMap<>();
    private final Set<String> engineClasses = new HashSet<>();
    private final Set<String> packages = new TreeSet<>();
    private final Map<String, List<BreakpointRequest>> pending = new HashMap<>();

    public static void main(String[] args) throws Exception {
        String cp = args[0];
        Path classes = Paths.get(args[1]);
        Path report = Paths.get(args[2]);
        double floor = Double.parseDouble(args[3]);
        String jvmOptions = args[4];
        Coverage c = new Coverage();
        c.scan(classes);
        List<String> commands = new ArrayList<>();
        commands.add(LoadAll.class.getName() + " " + classes.toAbsolutePath());
        for (int i = 5; i < args.length; i++) commands.add(args[i]);
        for (String cmd : commands) c.run(cp, jvmOptions, cmd);
        double pct = c.write(report);
        System.out.printf(Locale.ROOT, "coverage: %d of %d lines, %.1f %% (floor %.1f %%)%n", c.covered(), c.total(), pct, floor);
        System.exit(pct + 1e-9 >= floor ? 0 : 1);
    }

    private void scan(Path dir) throws IOException {
        try (Stream<Path> s = Files.walk(dir)) {
            s.filter(p -> p.toString().endsWith(".class")).forEach(p -> {
                String n = dir.relativize(p).toString().replace(java.io.File.separatorChar, '.');
                n = n.substring(0, n.length() - ".class".length());
                engineClasses.add(n);
                int dot = n.lastIndexOf('.');
                packages.add(dot < 0 ? "" : n.substring(0, dot));
            });
        }
    }

    private void run(String cp, String jvmOptions, String command) throws Exception {
        LaunchingConnector lc = Bootstrap.virtualMachineManager().defaultConnector();
        Map<String, Connector.Argument> a = lc.defaultArguments();
        a.get("main").setValue(command);
        a.get("options").setValue("-cp " + cp + " " + jvmOptions);
        VirtualMachine vm = lc.launch(a);
        Process p = vm.process();
        Thread out = pump(p.getInputStream(), System.err), err = pump(p.getErrorStream(), System.err);
        EventRequestManager erm = vm.eventRequestManager();
        for (String pkg : packages) {
            ClassPrepareRequest r = erm.createClassPrepareRequest();
            if (!pkg.isEmpty()) r.addClassFilter(pkg + ".*");
            r.setSuspendPolicy(EventRequest.SUSPEND_EVENT_THREAD);
            r.enable();
        }
        for (ReferenceType t : vm.allClasses()) prepared(erm, t);
        pending.clear();
        vm.resume();
        loop:
        while (true) {
            EventSet set = vm.eventQueue().remove();
            for (Event e : set) {
                if (e instanceof ClassPrepareEvent) prepared(erm, ((ClassPrepareEvent) e).referenceType());
                else if (e instanceof BreakpointEvent) hit(((BreakpointEvent) e).location());
                else if (e instanceof VMDisconnectEvent) break loop;
            }
            set.resume();
        }
        out.join();
        err.join();
        p.waitFor();
    }

    private static String key(Location l) {
        try {
            return l.sourcePath();
        } catch (AbsentInformationException e) {
            return l.declaringType().name();
        }
    }

    private void prepared(EventRequestManager erm, ReferenceType t) {
        if (!engineClasses.contains(t.name())) return;
        List<Location> locs;
        try {
            locs = t.allLineLocations();
        } catch (AbsentInformationException e) {
            return;
        }
        for (Location l : locs) {
            String file = key(l);
            Map<Integer, Boolean> m = lines.computeIfAbsent(file, f -> new TreeMap<>());
            Boolean covered = m.putIfAbsent(l.lineNumber(), false);
            if (Boolean.TRUE.equals(covered)) continue;
            BreakpointRequest b = erm.createBreakpointRequest(l);
            b.setSuspendPolicy(EventRequest.SUSPEND_EVENT_THREAD);
            b.enable();
            pending.computeIfAbsent(file + ":" + l.lineNumber(), k -> new ArrayList<>()).add(b);
        }
    }

    private void hit(Location l) {
        String file = key(l);
        lines.get(file).put(l.lineNumber(), true);
        List<BreakpointRequest> bs = pending.remove(file + ":" + l.lineNumber());
        if (bs != null) for (BreakpointRequest b : bs) b.disable();
    }

    private static Thread pump(InputStream in, OutputStream to) {
        Thread t = new Thread(() -> {
            byte[] buf = new byte[8192];
            try {
                int n;
                while ((n = in.read(buf)) > 0) to.write(buf, 0, n);
            } catch (IOException ignored) {
                // the VM went away
            }
        });
        t.start();
        return t;
    }

    long total() {
        long n = 0;
        for (Map<Integer, Boolean> m : lines.values()) n += m.size();
        return n;
    }

    long covered() {
        long n = 0;
        for (Map<Integer, Boolean> m : lines.values()) for (boolean b : m.values()) if (b) n++;
        return n;
    }

    private double write(Path report) throws IOException {
        StringBuilder b = new StringBuilder("file\tcovered\tlines\tpercent\tmissed lines\n");
        for (Map.Entry<String, Map<Integer, Boolean>> f : lines.entrySet()) {
            int c = 0;
            List<Integer> missed = new ArrayList<>();
            for (Map.Entry<Integer, Boolean> l : f.getValue().entrySet()) {
                if (l.getValue()) c++;
                else missed.add(l.getKey());
            }
            int n = f.getValue().size();
            b.append(String.format(Locale.ROOT, "%s\t%d\t%d\t%.1f\t%s%n", f.getKey(), c, n, 100.0 * c / n, missed));
        }
        double pct = total() == 0 ? 0 : 100.0 * covered() / total();
        b.append(String.format(Locale.ROOT, "TOTAL\t%d\t%d\t%.1f%n", covered(), total(), pct));
        Files.write(report, b.toString().getBytes(StandardCharsets.UTF_8));
        return pct;
    }
}
