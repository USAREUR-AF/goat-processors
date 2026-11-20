package goat.assign;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;

import static goat.correlate.CorrelatePack.atLeastOne;
import static goat.correlate.CorrelatePack.dec;
import static goat.correlate.CorrelatePack.err;
import static goat.correlate.CorrelatePack.integer;
import static goat.correlate.CorrelatePack.nonNegative;
import static goat.correlate.CorrelatePack.one;
import static goat.correlate.CorrelatePack.positive;

import goat.correlate.CorrelatePack;
import goat.correlate.Directive;
import goat.correlate.MethodKind;
import goat.correlate.Correlator;
import goat.correlate.Entity;
import goat.correlate.FrameMove;
import goat.correlate.Method;
import goat.correlate.Predicted;
import goat.model.Axis;
import goat.model.Frame;
import goat.model.InverseVariance;
import goat.model.KeyOrder;
import goat.trace.Records;
import goat.trace.Result;

/**
 * Method assign: correlate-assign.md. The entities, their filters and the tests are the
 * engine's; this class holds the memberships, the histories and the tick.
 */
public final class Assign implements Method {

    /** Method assign's registration: its directives (correlate-assign.md, Pack), the required ones, its checks. */
    public static final MethodKind KIND = new MethodKind("assign", Assign::new, List.of(
            // correlate-assign.md, Pack: new_cost above 0, keep_bonus 0 or above.
            new Directive("new_cost", false, (pk, tok, ln) ->
                    pk.newCost = positive(dec(one(tok, ln), ln), "new_cost", ln)),
            new Directive("keep_bonus", false, (pk, tok, ln) ->
                    pk.keepBonus = nonNegative(dec(one(tok, ln), ln), "keep_bonus", ln)),
            // Integers, 1 or above, written as one value.
            new Directive("window", false, (pk, tok, ln) ->
                    pk.window = atLeastOne(integer(one(tok, ln), ln), "window", ln)),
            new Directive("hypotheses", false, (pk, tok, ln) ->
                    pk.hypotheses = atLeastOne(integer(one(tok, ln), ln), "hypotheses", ln)),
            // One number above 0; needs hypotheses above 1 (checked at the end).
            new Directive("margin", false, (pk, tok, ln) -> {
                pk.margin = true;
                pk.marginValue = positive(dec(one(tok, ln), ln), "margin", ln);
            }),
            new Directive("bias", false, Bias::biasLine),
            new Directive("time_offset", false, Bias::timeOffsetLine)),
            List.of("pack", "version", "method", "filter", "new_cost", "keep_bonus", "stale_ms"),
            pk -> {
                if (pk.hypotheses > 1 && pk.window <= 1) throw err("hypotheses above 1 needs window above 1");
                if (pk.margin && pk.hypotheses <= 1) throw err("margin needs hypotheses above 1");
                if (pk.timeOffset && !pk.bias) throw err("time_offset needs bias");
            });

    private final Correlator engine;
    private final CorrelatePack pack;
    /** correlate-assign.md, Sensor bias, or null without the {@code bias} line. */
    private final Bias bias;
    private final boolean windowed;
    private Membership committed = new Membership();
    /** In rank order; at the start one history with no records. */
    private List<History> histories = new ArrayList<>(List.of(new History(new ArrayList<>())));
    /** The entities with an accepted report since the previous tick. */
    private final TreeSet<String> reported = new TreeSet<>(KeyOrder.KEY_ORDER);
    /** correlate.md, Restart: the entities whose filter started again since the previous tick. */
    private final TreeSet<String> restarted = new TreeSet<>(KeyOrder.KEY_ORDER);

    public Assign(Correlator engine, CorrelatePack pack) {
        this.engine = engine;
        this.pack = pack;
        this.bias = pack.bias ? new Bias(pack) : null;
        this.windowed = pack.window > 1;
    }

    /** A report gives only {@code new} or {@code reject}; the tick decides. */
    @Override
    public void reported(Entity a, Result res) {
        reported.add(a.key);
    }

    @Override
    public void restarted(String key) {
        restarted.add(key);
    }

    @Override
    public FrameMove frameMove() {
        return bias;
    }

    /** A history's latest membership: its newest record's, or the committed one. */
    private Membership latest(History h) {
        return h.records.isEmpty() ? committed : h.newest().membership;
    }

    // ---- Window: on each tick ----

    @Override
    public Result tick(long now) {
        Result res = new Result();

        // 1. Staleness, among entities that are not retiring, in key order.
        List<Entity> stale = new ArrayList<>();
        for (Entity e : engine.entities().values())
            if (!e.retiring && engine.isStale(e, now)) stale.add(e);
        for (History h : histories) {
            Record r = new Record(latest(h).copy());
            for (Entity e : stale) {
                if (r.membership.systemOf(e.key) != null) r.membership.leave(e.key, "stale", r.events);
                r.events.add(Records.ev("drop", "entity", e.key));
            }
            // Then each restarted entity that is not stale leaves its system track.
            for (String k : restarted) {
                if (stale.contains(engine.entities().get(k))) continue;
                if (r.membership.systemOf(k) != null) r.membership.leave(k, "restart", r.events);
            }
            h.records.add(r);
        }
        restarted.clear();
        for (Entity e : stale) e.retiring = true;

        // 2. Rows: reported since the previous tick, not stale, grouped by source.
        TreeMap<String, List<Entity>> bySource = new TreeMap<>(KeyOrder.KEY_ORDER);
        TreeSet<String> rows = new TreeSet<>(KeyOrder.KEY_ORDER);
        for (String k : reported) {
            Entity e = engine.entities().get(k);
            if (e.retiring) continue;
            rows.add(k);
            bySource.computeIfAbsent(e.source, s -> new ArrayList<>()).add(e);
        }
        reported.clear();

        // 3. Sources, in key order.
        for (Map.Entry<String, List<Entity>> s : bySource.entrySet())
            histories = assignSource(s.getKey(), s.getValue(), res);

        // 4. Commit, when the best history has n records.
        if (histories.get(0).records.size() == pack.window) commit(res);

        // 5. Bias: the update of Sensor bias, from the committed membership (also with margin).
        if (bias != null) bias.update(committed.systems, engine.entities(), rows, now, res.trace);

        // 6. Output: per committed system track, or with margin per track of the best history's
        //    latest membership; then the provisional tracks.
        Membership reportedSystems = pack.margin ? latest(histories.get(0)) : committed;
        for (Map.Entry<String, TreeSet<String>> st : reportedSystems.systems.entrySet())
            res.events.add(systemEvent(st.getKey(), st.getValue(), now));
        if (windowed)
            for (Map.Entry<String, TreeSet<String>> st : latest(histories.get(0)).systems.entrySet())
                res.events.add(Records.ev("provisional", "system", st.getKey(),
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
            if (windowed) res.trace.add(historyRec(i, null, "commit", h.total(), null, keep));
            if (keep) kept.add(h);
        }
        res.events.addAll(oldest.events);
        committed = oldest.membership;
        for (Map<String, Object> ev : oldest.events)
            if (ev.get("ev").equals("drop")) engine.entities().remove((String) ev.get("entity"));
        for (Entity e : engine.entities().values()) e.system = committed.systemOf(e.key);
        for (History h : kept) h.records.remove(0);
        histories = kept;
    }

    /** Window step 6: one event {@code system}, the fused estimate of all members at now. */
    private Map<String, Object> systemEvent(String name, TreeSet<String> keys, long now) {
        List<Entity> members = new ArrayList<>();
        for (String k : keys) members.add(engine.entities().get(k));
        Axis[] f = fusedEstimate(members, now, null);
        double[] ll = engine.toDegrees(f[0].p, f[1].p);
        double ve = f[0].v, vn = f[1].v;
        Map<String, Object> o = Records.ev("system", "system", name, "members", new ArrayList<Object>(keys),
                "lat", ll[0], "lon", ll[1], "course", Frame.course(ve, vn), "speed_ms", Math.hypot(ve, vn));
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
            List<Ranking.Ranked> ranked = Ranking.rank(prob.entry, prob.alone, prob.columns(), k);
            for (int r = 0; r < ranked.size(); r++) {
                Ranking.Ranked asg = ranked.get(r);
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
        // The first k are kept; with margin, of those only the ones with total at most cut = best + m.
        Double cut = pack.margin ? cands.get(0).total + pack.marginValue : null;
        List<History> next = new ArrayList<>();
        for (int c = 0; c < cands.size(); c++) {
            Candidate cd = cands.get(c);
            boolean kept = c < k && (cut == null || cd.total <= cut);
            if (windowed) res.trace.add(historyRec(cd.h, cd.r, "total", cd.total, cut, kept));
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
                Entity o = engine.entities().get(key);
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
     * With {@code frameOf} (Cost, a comparison with that entity), each member's predicted pp gets
     * its timing variance (correlate.md, Track estimate) and then, with bias, the member is moved
     * into that entity's frame (Sensor bias); the estimate for output does neither.
     */
    private Axis[] fusedEstimate(List<Entity> members, long t, Entity frameOf) {
        List<Axis[]> predicted = new ArrayList<>();
        for (Entity m : members) {
            Predicted pr = frameOf != null ? Predicted.forComparison(m, t) : Predicted.of(m, t);
            Axis[] ax = pr.axes();
            if (frameOf != null && bias != null) ax = bias.moveInto(frameOf.source, m.source, ax);
            predicted.add(ax);
        }
        return InverseVariance.combine(predicted);
    }

    /** Cost: d² of A against the fused estimate of M at A's last_time_ms. */
    private double cost(Entity a, List<Entity> m) {
        return cost(new Axis[] {a.filter.east(), a.filter.north()}, a.timingVar, fusedEstimate(m, a.lastTime, a));
    }

    /**
     * Cost, pure: sum over east, north of (p_a - p_f)² / (pp_a + pp_f), with pp_a A's pp plus A's
     * timing variance on that axis.
     */
    static double cost(Axis[] own, double[] timingVar, Axis[] fused) {
        double d2 = 0;
        for (int k = 0; k < 2; k++) {
            double d = own[k].p - fused[k].p;
            double ppA = own[k].pp + timingVar[k];
            d2 += d * d / (ppA + fused[k].pp);
        }
        return d2;
    }

    // ---- Assignment step 4: apply ----

    private static void apply(Problem prob, Ranking.Ranked asg, Record rec) {
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
                rec.events.add(Records.ev("join", "system", name, "entity", a));
            } else {
                String s = "s" + mem.nextSystem++;
                TreeSet<String> members = new TreeSet<>(KeyOrder.KEY_ORDER);
                members.add(a);
                mem.systems.put(s, members);
                rec.events.add(Records.ev("start", "system", s, "entity", a));
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

    private static Map<String, Object> historyRec(int a, Integer b, String test, double value, Double limit,
                                                  boolean pass) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("stage", "history");
        m.put("a", a);
        m.put("b", b);
        m.put("test", test);
        m.put("value", value);
        m.put("limit", limit);
        m.put("pass", pass);
        return m;
    }

    @Override
    public Map<String, Object> snapshot() {
        Map<String, Object> s = new LinkedHashMap<>();
        s.put("ref", engine.ref());
        Map<String, Object> ents = new LinkedHashMap<>();
        List<Object> retiring = new ArrayList<>();
        for (Entity e : engine.entities().values()) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("last_time_ms", e.lastTime);
            m.put("system", e.system);
            e.filter.putSnapshot(m);
            e.putTimeSnapshot(m);
            ents.put(e.key, m);
            if (e.retiring) retiring.add(e.key);
        }
        s.put("entities", ents);
        s.put("systems", committed.systemsMap());
        s.put("next_system", committed.nextSystem);
        s.put("reported", new ArrayList<Object>(reported));
        if (pack.restart) s.put("restarted", new ArrayList<Object>(restarted));
        if (bias != null) s.put("bias", bias.snapshot());
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
