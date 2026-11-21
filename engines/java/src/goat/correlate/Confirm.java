package goat.correlate;

import goat.model.Axis;
import goat.model.Frame;
import goat.model.KeyOrder;
import goat.trace.Records;
import goat.trace.Result;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

/**
 * Method confirm (correlate.md 1.0): Association (associate, hold, leave; with {@code sprt}, the
 * Sequential test), On each tick (staleness, fused output) and the Snapshot.
 */
final class Confirm implements Method {

    /** correlate.md, Pack: the values of {@code output}. */
    private static final List<String> OUTPUTS = List.of("fused", "priority", "latest");

    /** Method confirm's registration: its directives (correlate.md, Pack) and the required ones. */
    static final MethodKind KIND = new MethodKind("confirm", Confirm::new, List.of(
            new Directive("confirm", true, (pk, tok, ln) -> pk.confirm.add(CorrelatePack.test(pk, tok, ln))),
            new Directive("hold", true, (pk, tok, ln) -> pk.hold.add(CorrelatePack.test(pk, tok, ln))),
            new Directive("confirm_count", false,
                    (pk, tok, ln) -> pk.confirmCount = CorrelatePack.integer(CorrelatePack.one(tok, ln), ln)),
            new Directive("hold_failures", false,
                    (pk, tok, ln) -> pk.holdFailures = CorrelatePack.integer(CorrelatePack.one(tok, ln), ln)),
            new Directive("same_source", false, (pk, tok, ln) -> {
                String v = CorrelatePack.one(tok, ln);
                if (v.equals("allow")) pk.sameSourceAllow = true;
                else if (!v.equals("forbid")) throw CorrelatePack.err(ln, "same_source is forbid or allow");
            }),
            new Directive("output", false, (pk, tok, ln) -> {
                String v = CorrelatePack.one(tok, ln);
                if (!OUTPUTS.contains(v)) throw CorrelatePack.err(ln, "output is fused, priority or latest");
                pk.output = v;
            }),
            new Directive("sprt", false, Sprt::line),
            new Directive("priority", true, (pk, tok, ln) -> {
                if (tok.length != 3) throw CorrelatePack.err(ln, "priority <source_id> <n>");
                if (pk.priority.containsKey(tok[1])) throw CorrelatePack.err(ln, "repeated priority " + tok[1]);
                pk.priority.put(tok[1], CorrelatePack.integer(tok[2], ln));
            })),
            List.of("pack", "version", "filter"),
            pk -> {
                // correlate.md, Pack: with sprt, confirm_count, hold_failures and hold are load
                // errors; without it, confirm_count and hold_failures are required.
                for (String d : List.of("confirm_count", "hold_failures", "hold")) {
                    if (pk.sprt && pk.seen.contains(d)) throw CorrelatePack.err(d + " is a load error with sprt");
                    if (!pk.sprt && !d.equals("hold") && !pk.seen.contains(d))
                        throw CorrelatePack.err("missing directive " + d);
                }
            });


    private final Correlator engine;
    private final CorrelatePack pack;
    private final LinkedHashMap<String, TreeSet<String>> groups = new LinkedHashMap<>();
    private final TreeMap<String, Long> counts = new TreeMap<>(KeyOrder.KEY_ORDER);
    /** Sequential test: each pair's {@code L}, by pair key. */
    private final TreeMap<String, Double> llr = new TreeMap<>(KeyOrder.KEY_ORDER);
    private long nextGroup = 1;
    /** Sequential test: the bounds, and the {@code same} tests of the gate line in pack order. */
    private final double up, lo;
    private final List<CorrelatePack.Test> gateSame = new ArrayList<>();

    Confirm(Correlator engine, CorrelatePack pack) {
        this.engine = engine;
        this.pack = pack;
        this.up = pack.sprt ? Sprt.up(pack) : 0;
        this.lo = pack.sprt ? Sprt.lo(pack) : 0;
        for (CorrelatePack.Test t : pack.gate) if (t.name.equals("same")) gateSame.add(t);
    }

    @Override
    public void reported(Entity a, Result res) {
        if (pack.sprt) {
            if (a.group != null) sprtLink(a, res);
            else sprtAssociate(a, res);
        } else if (a.group != null) hold(a, res);
        else associate(a, res);
    }

    // ---- Sequential test (Association, "Sequential test") ----

    /** "A is in a group G": update the link pair only; release A when its L falls to lo. */
    private void sprtLink(Entity a, Result res) {
        Entity link = null;
        double best = 0;
        for (String m : groups.get(a.group)) {
            if (m.equals(a.key)) continue;
            double l = llr.getOrDefault(pairKey(a.key, m), 0.0);
            if (link == null || l > best) {
                link = engine.entities.get(m);
                best = l;
            }
        }
        boolean forced = !engine.runTests(gateSame, "gate", a, link, res);
        double l = sprtUpdate(a, link, forced, res);
        if (l > lo) return;
        leave(a, "release", res);
        llr.entrySet().removeIf(en -> names(en.getKey(), a.key) && en.getValue() <= lo);
    }

    /** "A is not in a group": every candidate's pair, then the ready one with the smallest d². */
    private void sprtAssociate(Entity a, Result res) {
        List<Entity> ready = new ArrayList<>();
        for (Entity b : candidates(a)) {
            boolean all = engine.runTests(pack.gate, "gate", a, b, res)
                    && engine.runTests(pack.confirm, "confirm", a, b, res);
            String pk = pairKey(a.key, b.key);
            boolean forced = false;
            if (!all) {
                if (!llr.containsKey(pk)) continue;
                forced = !engine.runTests(gateSame, "gate", a, b, new Result());
            }
            double l = sprtUpdate(a, b, forced, res);
            if (l <= lo) llr.remove(pk);
            else if (l >= up) ready.add(b);
        }
        Entity chosen = rank(a, ready, res);
        if (chosen != null) group(a, chosen, res);
    }

    /** Update of a pair: adds A's evidence, or forced to lo; writes its sprt record; returns the new L. */
    private double sprtUpdate(Entity a, Entity b, boolean forced, Result res) {
        String pk = pairKey(a.key, b.key);
        Double inc = null, d2 = null;
        double l;
        if (forced) l = lo;
        else {
            double[] ev = Sprt.evidence(pack, a, b, Predicted.forComparison(b, a.lastTime));
            inc = ev[0];
            d2 = ev[1];
            l = Sprt.update(llr.getOrDefault(pk, 0.0), inc, lo, up);
        }
        llr.put(pk, l);
        Map<String, Object> r = Tests.rec("sprt", a, b, "llr", l, up, l >= up, false);
        r.put("lower", lo);
        r.put("increment", inc);
        r.put("d2", d2);
        res.trace.add(r);
        return l;
    }

    /** True when pair key k names entity key. */
    private static boolean names(String k, String key) {
        String[] ab = k.split("\\|", 2);
        return ab[0].equals(key) || ab[1].equals(key);
    }

    /** Association, "A is in a group G: hold". */
    private void hold(Entity a, Result res) {
        String g = a.group;
        boolean held = false;
        for (String m : groups.get(g)) {
            if (m.equals(a.key)) continue;
            if (engine.runTests(pack.hold, "hold", a, engine.entities.get(m), res)) {
                held = true;
                break;
            }
        }
        if (held) {
            a.holdFailures = 0;
            return;
        }
        a.holdFailures += 1;
        if (a.holdFailures >= pack.holdFailures) {
            a.holdFailures = 0;
            leave(a, "hold", res);
        }
    }

    /** Association, "A is not in a group: associate". */
    private void associate(Entity a, Result res) {
        List<Entity> reached = new ArrayList<>();
        for (Entity b : candidates(a)) {
            boolean all = engine.runTests(pack.gate, "gate", a, b, res)
                    && engine.runTests(pack.confirm, "confirm", a, b, res);
            String pk = pairKey(a.key, b.key);
            long count = all ? counts.getOrDefault(pk, 0L) + 1 : 0;
            counts.put(pk, count);
            boolean ok = count >= pack.confirmCount;
            res.trace.add(Tests.rec("confirm", a, b, "count", count, pack.confirmCount, ok, false));
            if (ok) reached.add(b);
        }
        Entity chosen = rank(a, reached, res);
        if (chosen == null) return;
        group(a, chosen, res);
        counts.put(pairKey(a.key, chosen.key), 0L);
    }

    /** Associate's candidates: every other entity in key order, less those same_source forbids. */
    private List<Entity> candidates(Entity a) {
        List<Entity> out = new ArrayList<>();
        for (Entity b : engine.entities.values()) {
            if (b == a) continue;
            if (!pack.sameSourceAllow) {
                if (b.source.equals(a.source)) continue;
                if (b.group != null && groupHoldsSource(b.group, a.source)) continue;
            }
            out.add(b);
        }
        return out;
    }

    /** The rank records, in key order; the candidate with the smallest position d², ties to key order. */
    private Entity rank(Entity a, List<Entity> reached, Result res) {
        Entity chosen = null;
        double best = 0;
        for (Entity b : reached) {
            double d2 = Tests.mahalanobis(a, Predicted.forComparison(b, a.lastTime));
            res.trace.add(Tests.rec("rank", a, b, "rank", d2, null, true, false));
            if (chosen == null || d2 < best) {
                chosen = b;
                best = d2;
            }
        }
        return chosen;
    }

    /** A joins the chosen entity's group, or the two make a new one. */
    private void group(Entity a, Entity chosen, Result res) {
        if (chosen.group != null) {
            groups.get(chosen.group).add(a.key);
            a.group = chosen.group;
            res.events.add(Records.ev("join", "group", a.group, "entity", a.key));
        } else {
            String g = "g" + nextGroup++;
            TreeSet<String> members = new TreeSet<>(KeyOrder.KEY_ORDER);
            members.add(a.key);
            members.add(chosen.key);
            groups.put(g, members);
            a.group = g;
            chosen.group = g;
            res.events.add(Records.ev("correlate", "group", g, "members", new ArrayList<Object>(members)));
        }
    }

    private boolean groupHoldsSource(String g, String source) {
        for (String m : groups.get(g)) if (engine.entities.get(m).source.equals(source)) return true;
        return false;
    }

    /** Leave a group; dissolve it when one member is left (Association). */
    private void leave(Entity e, String reason, Result res) {
        String g = e.group;
        TreeSet<String> members = groups.get(g);
        members.remove(e.key);
        e.group = null;
        res.events.add(Records.ev("leave", "group", g, "entity", e.key, "reason", reason));
        if (members.size() == 1) {
            Entity rest = engine.entities.get(members.first());
            rest.group = null;
            rest.holdFailures = 0;
            groups.remove(g);
            res.events.add(Records.ev("dissolve", "group", g, "entity", rest.key));
        }
    }

    // ---- tick (Association "On each tick") ----

    @Override
    public Result tick(long now) {
        Result res = new Result();
        // 1. Staleness
        for (Entity e : new ArrayList<>(engine.entities.values())) {
            if (!engine.isStale(e, now)) continue;
            if (e.group != null) leave(e, "stale", res);
            engine.entities.remove(e.key);
            counts.keySet().removeIf(k -> names(k, e.key));
            llr.keySet().removeIf(k -> names(k, e.key));
            res.events.add(Records.ev("drop", "entity", e.key));
        }
        // 2. Fused output
        for (Map.Entry<String, TreeSet<String>> g : groups.entrySet()) {
            if (pack.output.equals("fused")) {
                res.events.add(fused(g.getKey(), g.getValue(), now));
                continue;
            }
            Entity primary = null;
            for (String m : g.getValue()) {
                Entity e = engine.entities.get(m);
                if (primary == null || better(e, primary)) primary = e;
            }
            Predicted p = Predicted.of(primary, now);
            double[] ll = engine.toDegrees(p.east.p, p.north.p);
            double ve = p.east.v, vn = p.north.v;
            double course = Frame.course(ve, vn);
            Map<String, Object> f = Records.ev("fused", "group", g.getKey(), "primary", primary.key,
                    "members", new ArrayList<Object>(g.getValue()), "lat", ll[0], "lon", ll[1],
                    "course", course, "speed_ms", Math.hypot(ve, vn));
            Double hae = primary.num("hae");
            if (hae != null) f.put("hae", hae);
            res.events.add(f);
        }
        return res;
    }

    /**
     * Fused output with {@code output fused}: per axis the information-weighted combination of
     * every member's filter predicted to now (no timing variance), members in key order.
     */
    private Map<String, Object> fused(String g, TreeSet<String> members, long now) {
        double[] sumP = new double[2], invPP = new double[2], sumV = new double[2], invVV = new double[2];
        Entity haeFrom = null;
        for (String m : members) {
            Entity e = engine.entities.get(m);
            Predicted pr = Predicted.of(e, now);
            Axis[] ax = pr.axes();
            for (int k = 0; k < 2; k++) {
                sumP[k] += ax[k].p / ax[k].pp;
                invPP[k] += 1 / ax[k].pp;
                sumV[k] += ax[k].v / ax[k].vv;
                invVV[k] += 1 / ax[k].vv;
            }
            if (e.num("hae") != null && (haeFrom == null || e.lastTime > haeFrom.lastTime)) haeFrom = e;
        }
        double pe = sumP[0] / invPP[0], pn = sumP[1] / invPP[1];
        double ve = sumV[0] / invVV[0], vn = sumV[1] / invVV[1];
        double[] ll = engine.toDegrees(pe, pn);
        Map<String, Object> f = Records.ev("fused", "group", g, "primary", null,
                "members", new ArrayList<Object>(members), "lat", ll[0], "lon", ll[1],
                "course", Frame.course(ve, vn), "speed_ms", Math.hypot(ve, vn));
        if (haeFrom != null) f.put("hae", haeFrom.num("hae"));
        return f;
    }

    /** True when e beats the current primary; members are visited in key order so ties keep the earlier. */
    private boolean better(Entity e, Entity cur) {
        if (pack.output.equals("latest")) return e.lastTime > cur.lastTime;
        return priorityOf(e) < priorityOf(cur);
    }

    private long priorityOf(Entity e) {
        return pack.priority.getOrDefault(e.source, 100L);
    }

    // ---- snapshot (Snapshot) ----

    @Override
    public Map<String, Object> snapshot() {
        Map<String, Object> s = new LinkedHashMap<>();
        s.put("ref", engine.ref());
        Map<String, Object> ents = new LinkedHashMap<>();
        for (Entity e : engine.entities.values()) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("last_time_ms", e.lastTime);
            m.put("group", e.group);
            m.put("hold_failures", e.holdFailures);
            e.filter.putSnapshot(m);
            e.putTimeSnapshot(m);
            ents.put(e.key, m);
        }
        s.put("entities", ents);
        Map<String, Object> gs = new LinkedHashMap<>();
        for (Map.Entry<String, TreeSet<String>> g : groups.entrySet())
            gs.put(g.getKey(), new ArrayList<Object>(g.getValue()));
        s.put("groups", gs);
        s.put("counts", new LinkedHashMap<String, Object>(counts));
        s.put("next_group", nextGroup);
        if (pack.sprt) s.put("llr", new LinkedHashMap<String, Object>(llr));
        engine.putIntervals(s);
        return s;
    }

    private static String pairKey(String x, String y) {
        return KeyOrder.KEY_ORDER.compare(x, y) <= 0 ? x + "|" + y : y + "|" + x;
    }
}
