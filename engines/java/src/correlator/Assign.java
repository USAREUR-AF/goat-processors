package correlator;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;

import correlator.Engine.Entity;
import correlator.Engine.Result;

/**
 * Method assign: correlate-assign.md. The entities, their filters and the tests are the
 * engine's; this class holds the memberships, the histories and the tick.
 */
final class Assign {

    // ---- Memberships ----

    /** One picture of the system tracks: members per track in creation order, and the counter. */
    static final class Membership {
        final LinkedHashMap<String, TreeSet<String>> systems = new LinkedHashMap<>();
        long nextSystem = 1;

        Membership copy() {
            Membership m = new Membership();
            for (Map.Entry<String, TreeSet<String>> s : systems.entrySet())
                m.systems.put(s.getKey(), new TreeSet<>(s.getValue()));
            m.nextSystem = nextSystem;
            return m;
        }

        /** The system track holding the entity, or null. */
        String systemOf(String key) {
            for (Map.Entry<String, TreeSet<String>> s : systems.entrySet())
                if (s.getValue().contains(key)) return s.getKey();
            return null;
        }

        /** The entity is the only member of its system track. */
        boolean isAlone(String key) {
            String s = systemOf(key);
            return s != null && systems.get(s).size() == 1;
        }

        /** The entity leaves its system track (event leave); a track left empty ends (event end). */
        void leave(String key, String reason, List<Map<String, Object>> events) {
            String s = systemOf(key);
            TreeSet<String> members = systems.get(s);
            members.remove(key);
            events.add(Engine.ev("leave", "system", s, "entity", key, "reason", reason));
            if (members.isEmpty()) {
                systems.remove(s);
                events.add(Engine.ev("end", "system", s));
            }
        }

        Map<String, Object> systemsMap() {
            Map<String, Object> ss = new LinkedHashMap<>();
            for (Map.Entry<String, TreeSet<String>> s : systems.entrySet())
                ss.put(s.getKey(), new ArrayList<Object>(s.getValue()));
            return ss;
        }
    }

    /** One pending tick of a history. Never changed once a later record or a copy exists. */
    static final class Record {
        double cost;
        final List<List<Object>> choices = new ArrayList<>();
        final List<Map<String, Object>> events = new ArrayList<>();
        Membership membership;

        Record(Membership membership) {
            this.membership = membership;
        }

        Record copy() {
            Record r = new Record(membership.copy());
            r.cost = cost;
            r.choices.addAll(choices);
            r.events.addAll(events);
            return r;
        }
    }

    /** A list of pending ticks, oldest first. */
    static final class History {
        final List<Record> records;

        History(List<Record> records) {
            this.records = records;
        }

        /** Memberships: the sum, left to right from 0, of the records' cost, oldest first. */
        double total() {
            double t = 0;
            for (Record r : records) t += r.cost;
            return t;
        }

        Record newest() {
            return records.get(records.size() - 1);
        }
    }

    private final Engine engine;
    private final Pack pack;
    private final boolean windowed;
    private Membership committed = new Membership();
    /** In rank order; at the start one history with no records. */
    private List<History> histories = new ArrayList<>(List.of(new History(new ArrayList<>())));
    /** The entities with an accepted report since the previous tick. */
    private final TreeSet<String> reported = new TreeSet<>(Engine.KEY_ORDER);

    Assign(Engine engine, Pack pack) {
        this.engine = engine;
        this.pack = pack;
        this.windowed = pack.window > 1;
    }

    void reported(String key) {
        reported.add(key);
    }

    /** A history's latest membership: its newest record's, or the committed one. */
    private Membership latest(History h) {
        return h.records.isEmpty() ? committed : h.newest().membership;
    }

    // ---- Window: on each tick ----

    Result tick(long now) {
        Result res = new Result();

        // 1. Staleness, among entities that are not retiring, in key order.
        List<Entity> stale = new ArrayList<>();
        for (Entity e : engine.entities.values())
            if (!e.retiring && engine.isStale(e, now)) stale.add(e);
        for (History h : histories) {
            Record r = new Record(latest(h).copy());
            for (Entity e : stale) {
                if (r.membership.systemOf(e.key) != null) r.membership.leave(e.key, "stale", r.events);
                r.events.add(Engine.ev("drop", "entity", e.key));
            }
            h.records.add(r);
        }
        for (Entity e : stale) e.retiring = true;

        // 2. Rows: reported since the previous tick, not stale, grouped by source.
        TreeMap<String, List<Entity>> bySource = new TreeMap<>(Engine.KEY_ORDER);
        for (String k : reported) {
            Entity e = engine.entities.get(k);
            if (e.retiring) continue;
            bySource.computeIfAbsent(e.source, s -> new ArrayList<>()).add(e);
        }
        reported.clear();

        // 3. Sources, in key order.
        for (Map.Entry<String, List<Entity>> s : bySource.entrySet())
            histories = assignSource(s.getKey(), s.getValue(), res);

        // 4. Commit, when the best history has n records.
        if (histories.get(0).records.size() == pack.window) commit(res);

        // 5. Output.
        for (Map.Entry<String, TreeSet<String>> st : committed.systems.entrySet())
            res.events.add(systemEvent(st.getKey(), st.getValue(), now));
        if (windowed)
            for (Map.Entry<String, TreeSet<String>> st : latest(histories.get(0)).systems.entrySet())
                res.events.add(Engine.ev("provisional", "system", st.getKey(),
                        "members", new ArrayList<Object>(st.getValue())));
        return res;
    }

    /** Window step 4: commit the best history's oldest record and prune the others. */
    private void commit(Result res) {
        Record oldest = histories.get(0).records.get(0);
        List<History> kept = new ArrayList<>();
        for (int i = 0; i < histories.size(); i++) {
            History h = histories.get(i);
            boolean keep = h.records.get(0).choices.equals(oldest.choices);
            if (windowed) res.trace.add(historyRec(i, null, "commit", h.total(), keep));
            if (keep) kept.add(h);
        }
        res.events.addAll(oldest.events);
        committed = oldest.membership;
        for (Map<String, Object> ev : oldest.events)
            if (ev.get("ev").equals("drop")) engine.entities.remove((String) ev.get("entity"));
        for (Entity e : engine.entities.values()) e.system = committed.systemOf(e.key);
        for (History h : kept) h.records.remove(0);
        histories = kept;
    }

    /** Window step 5: one event {@code system}, the fused estimate of all members at now. */
    private Map<String, Object> systemEvent(String name, TreeSet<String> keys, long now) {
        List<Entity> members = new ArrayList<>();
        for (String k : keys) members.add(engine.entities.get(k));
        Filter.Axis[] f = fusedEstimate(members, now);
        double[] ll = engine.toDegrees(f[0].p, f[1].p);
        double ve = f[0].v, vn = f[1].v;
        Map<String, Object> o = Engine.ev("system", "system", name, "members", new ArrayList<Object>(keys),
                "lat", ll[0], "lon", ll[1], "course", Engine.course(ve, vn), "speed_ms", Math.hypot(ve, vn));
        // hae from the member with the greatest last_time_ms that has one; members are in key order.
        Entity haeFrom = null;
        for (Entity m : members)
            if (m.num("hae") != null && (haeFrom == null || m.lastTime > haeFrom.lastTime)) haeFrom = m;
        if (haeFrom != null) o.put("hae", haeFrom.num("hae"));
        return o;
    }

    // ---- Window step 3: one source over every history ----

    private static final class Candidate {
        final History history;
        final int h, r;
        final double total;

        Candidate(History history, int h, int r) {
            this.history = history;
            this.h = h;
            this.r = r;
            this.total = history.total();
        }
    }

    private List<History> assignSource(String source, List<Entity> rows, Result res) {
        int k = (int) pack.hypotheses;
        List<Candidate> cands = new ArrayList<>();
        for (int h = 0; h < histories.size(); h++) {
            History hist = histories.get(h);
            Record newest = hist.newest();
            int from = res.trace.size();
            Problem prob = entries(source, rows, newest.membership, res);
            tag(res.trace, from, h, null);
            List<Ranked> ranked = rank(prob, k);
            for (int r = 0; r < ranked.size(); r++) {
                Ranked asg = ranked.get(r);
                from = res.trace.size();
                for (int i = 0; i < rows.size(); i++)
                    res.trace.add(assignRec(rows.get(i), prob.name(asg.choice[i]), "choice", prob.entry(i, asg.choice[i]), true));
                tag(res.trace, from, h, r);
                // The candidate: h with its newest record replaced by a copy with the assignment applied.
                Record rec = newest.copy();
                apply(prob, asg, rec);
                rec.cost = newest.cost + asg.total;
                List<Record> records = new ArrayList<>(hist.records.subList(0, hist.records.size() - 1));
                records.add(rec);
                cands.add(new Candidate(new History(records), h, r));
            }
        }
        // Ordered by total, then h, then r: candidates are built in (h, r) order and the sort is stable.
        cands.sort((x, y) -> x.total < y.total ? -1 : x.total > y.total ? 1 : 0);
        List<History> next = new ArrayList<>();
        for (int c = 0; c < cands.size(); c++) {
            Candidate cd = cands.get(c);
            boolean kept = c < k;
            if (windowed) res.trace.add(historyRec(cd.h, cd.r, "total", cd.total, kept));
            if (kept) next.add(cd.history);
        }
        return next;
    }

    /** With window above 1, the source's records carry {@code h}, and choice records {@code r}. */
    private void tag(List<Map<String, Object>> trace, int from, int h, Integer r) {
        if (!windowed) return;
        for (int i = from; i < trace.size(); i++) {
            trace.get(i).put("h", h);
            if (r != null) trace.get(i).put("r", r);
        }
    }

    // ---- Assignment of one source, steps 1 and 2 ----

    /** The columns and entries of one source against one membership. */
    private static final class Problem {
        final List<String> colNames = new ArrayList<>();
        final List<List<Entity>> colOthers = new ArrayList<>();
        /** entry[i][j] for row i and column j, null when forbidden; alone[i] its alone entry. */
        Double[][] entry;
        double[] alone;
        List<Entity> rows;

        int columns() {
            return colNames.size();
        }

        /** Choice index j: a column, or columns() for alone. */
        String name(int j) {
            return j < columns() ? colNames.get(j) : "alone";
        }

        double entry(int i, int j) {
            return j < columns() ? entry[i][j] : alone[i];
        }
    }

    private Problem entries(String source, List<Entity> rows, Membership mem, Result res) {
        Problem prob = new Problem();
        prob.rows = rows;
        Set<String> rKeys = new HashSet<>();
        for (Entity a : rows) rKeys.add(a.key);

        // 1. Columns: tracks whose members outside R are not empty and hold no entity of S.
        for (Map.Entry<String, TreeSet<String>> st : mem.systems.entrySet()) {
            List<Entity> others = new ArrayList<>();
            boolean holdsSource = false;
            for (String key : st.getValue()) {
                if (rKeys.contains(key)) continue;
                Entity o = engine.entities.get(key);
                if (o.source.equals(source)) holdsSource = true;
                others.add(o);
            }
            if (others.isEmpty() || holdsSource) continue;
            prob.colNames.add(st.getKey());
            prob.colOthers.add(others);
        }

        // 2. Entries: gate against each other in key order, the first failure ends the entry.
        int n = rows.size(), k = prob.columns();
        prob.entry = new Double[n][k];
        prob.alone = new double[n];
        for (int i = 0; i < n; i++) {
            Entity a = rows.get(i);
            String own = mem.systemOf(a.key);
            for (int j = 0; j < k; j++) {
                boolean pass = true;
                for (Entity o : prob.colOthers.get(j)) {
                    if (!engine.runTests(pack.gate, "gate", a, o, res)) {
                        pass = false;
                        break;
                    }
                }
                if (!pass) continue;
                double c = cost(a, prob.colOthers.get(j));
                if (prob.colNames.get(j).equals(own)) c -= pack.keepBonus;
                prob.entry[i][j] = c;
            }
            prob.alone[i] = pack.newCost - (mem.isAlone(a.key) ? pack.keepBonus : 0);
        }
        for (int i = 0; i < n; i++) {
            Entity a = rows.get(i);
            for (int j = 0; j < k; j++)
                res.trace.add(assignRec(a, prob.colNames.get(j), "cost", prob.entry[i][j], prob.entry[i][j] != null));
            res.trace.add(assignRec(a, "alone", "cost", prob.alone[i], true));
        }
        return prob;
    }

    /**
     * Fused estimate of a set of entities at t: each member's filter predicted to t, combined per
     * axis by inverse-variance weights, members in key order. pv of the result is unused and 0.
     */
    private static Filter.Axis[] fusedEstimate(List<Entity> members, long t) {
        double[] invPP = new double[2], sumP = new double[2], invVV = new double[2], sumV = new double[2];
        for (Entity m : members) {
            Engine.Predicted pr = new Engine.Predicted(m, t);
            Filter.Axis[] axes = {pr.east, pr.north};
            for (int k = 0; k < 2; k++) {
                invPP[k] += 1 / axes[k].pp;
                sumP[k] += axes[k].p / axes[k].pp;
                invVV[k] += 1 / axes[k].vv;
                sumV[k] += axes[k].v / axes[k].vv;
            }
        }
        Filter.Axis[] out = new Filter.Axis[2];
        for (int k = 0; k < 2; k++) {
            double pp = 1 / invPP[k], vv = 1 / invVV[k];
            out[k] = new Filter.Axis(pp * sumP[k], vv * sumV[k], pp, 0, vv);
        }
        return out;
    }

    /** Cost: d² of A against the fused estimate of M at A's last_time_ms. */
    private static double cost(Entity a, List<Entity> m) {
        Filter.Axis[] f = fusedEstimate(m, a.lastTime);
        Filter.Axis[] own = {a.filter.east(), a.filter.north()};
        double d2 = 0;
        for (int k = 0; k < 2; k++) {
            double d = own[k].p - f[k].p;
            d2 += d * d / (own[k].pp + f[k].pp);
        }
        return d2;
    }

    // ---- Assignment step 3 and Ranking ----

    /** One assignment: its choice vector (column index, or columns() for alone) and its total. */
    private static final class Ranked {
        final int[] choice;
        final double total;

        Ranked(int[] choice, double total) {
            this.choice = choice;
            this.total = total;
        }
    }

    /**
     * The first k assignments in the Ranking order, by enumerating every assignment. The
     * enumeration visits choice vectors in ascending order, so a stable sort by total gives the
     * order "total, then choice vector".
     */
    private static List<Ranked> rank(Problem prob, int k) {
        List<Ranked> all = new ArrayList<>();
        enumerate(prob, 0, new int[prob.rows.size()], new boolean[prob.columns()], all);
        all.sort((x, y) -> x.total < y.total ? -1 : x.total > y.total ? 1 : 0);
        return all.subList(0, Math.min(k, all.size()));
    }

    private static void enumerate(Problem prob, int i, int[] choice, boolean[] used, List<Ranked> out) {
        int n = prob.rows.size(), cols = prob.columns();
        if (i == n) {
            out.add(new Ranked(choice.clone(), total(prob, choice)));
            return;
        }
        for (int j = 0; j <= cols; j++) {
            if (j < cols && (used[j] || prob.entry[i][j] == null)) continue;
            choice[i] = j;
            if (j < cols) used[j] = true;
            enumerate(prob, i + 1, choice, used, out);
            if (j < cols) used[j] = false;
        }
    }

    /** Ranking: the chosen entries taken in ascending order of value, added left to right from 0. */
    private static double total(Problem prob, int[] choice) {
        double[] v = new double[choice.length];
        for (int i = 0; i < choice.length; i++) v[i] = prob.entry(i, choice[i]);
        Arrays.sort(v);
        double t = 0;
        for (double x : v) t += x;
        return t;
    }

    // ---- Assignment step 4: apply ----

    private static void apply(Problem prob, Ranked asg, Record rec) {
        Membership mem = rec.membership;
        for (int i = 0; i < prob.rows.size(); i++) {
            String a = prob.rows.get(i).key;
            int j = asg.choice[i];
            String name = prob.name(j);
            rec.choices.add(List.of(a, name));
            String own = mem.systemOf(a);
            boolean toColumn = j < prob.columns();
            if (toColumn ? name.equals(own) : mem.isAlone(a)) continue;
            if (own != null) mem.leave(a, "assign", rec.events);
            if (toColumn) {
                mem.systems.get(name).add(a);
                rec.events.add(Engine.ev("join", "system", name, "entity", a));
            } else {
                String s = "s" + mem.nextSystem++;
                TreeSet<String> members = new TreeSet<>(Engine.KEY_ORDER);
                members.add(a);
                mem.systems.put(s, members);
                rec.events.add(Engine.ev("start", "system", s, "entity", a));
            }
        }
    }

    // ---- Trace and Snapshot ----

    private static Map<String, Object> assignRec(Entity a, String b, String test, Double value, boolean pass) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("stage", "assign");
        m.put("a", a.key);
        m.put("b", b);
        m.put("test", test);
        m.put("value", value);
        m.put("limit", null);
        m.put("pass", pass);
        return m;
    }

    private static Map<String, Object> historyRec(int a, Integer b, String test, double value, boolean pass) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("stage", "history");
        m.put("a", a);
        m.put("b", b);
        m.put("test", test);
        m.put("value", value);
        m.put("limit", null);
        m.put("pass", pass);
        return m;
    }

    Map<String, Object> snapshot() {
        Map<String, Object> s = new LinkedHashMap<>();
        s.put("ref", engine.lat0 == null ? null : List.of(engine.lat0, engine.lon0));
        Map<String, Object> ents = new LinkedHashMap<>();
        List<Object> retiring = new ArrayList<>();
        for (Entity e : engine.entities.values()) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("last_time_ms", e.lastTime);
            m.put("system", e.system);
            e.filter.putSnapshot(m);
            ents.put(e.key, m);
            if (e.retiring) retiring.add(e.key);
        }
        s.put("entities", ents);
        s.put("systems", committed.systemsMap());
        s.put("next_system", committed.nextSystem);
        s.put("reported", new ArrayList<Object>(reported));
        if (!windowed) return s;
        s.put("retiring", retiring);
        List<Object> hs = new ArrayList<>();
        for (History h : histories) {
            List<Object> recs = new ArrayList<>();
            for (Record r : h.records) {
                Map<String, Object> rm = new LinkedHashMap<>();
                rm.put("cost", r.cost);
                rm.put("choices", new ArrayList<Object>(r.choices));
                rm.put("events", new ArrayList<Object>(r.events));
                rm.put("systems", r.membership.systemsMap());
                rm.put("next_system", r.membership.nextSystem);
                recs.add(rm);
            }
            Map<String, Object> hm = new LinkedHashMap<>();
            hm.put("total", h.total());
            hm.put("records", recs);
            hs.add(hm);
        }
        s.put("histories", hs);
        return s;
    }
}
