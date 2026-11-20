package goat.correlate;

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
 * Method confirm (correlate.md): Association (associate, hold, leave), On each tick
 * (staleness, fused output) and the Snapshot. Moved unchanged into this layout; correlate 1.0
 * replaces this pipeline.
 */
final class Confirm implements Method {

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
                if (v.equals("latest")) pk.outputLatest = true;
                else if (!v.equals("priority")) throw CorrelatePack.err(ln, "output is priority or latest");
            }),
            new Directive("priority", true, (pk, tok, ln) -> {
                if (tok.length != 3) throw CorrelatePack.err(ln, "priority <source_id> <n>");
                if (pk.priority.containsKey(tok[1])) throw CorrelatePack.err(ln, "repeated priority " + tok[1]);
                pk.priority.put(tok[1], CorrelatePack.integer(tok[2], ln));
            })),
            List.of("pack", "version", "filter", "confirm_count", "hold_failures", "stale_ms"),
            pk -> {});

    private final Correlator engine;
    private final CorrelatePack pack;
    private final LinkedHashMap<String, TreeSet<String>> groups = new LinkedHashMap<>();
    private final TreeMap<String, Long> counts = new TreeMap<>(KeyOrder.KEY_ORDER);
    private long nextGroup = 1;

    Confirm(Correlator engine, CorrelatePack pack) {
        this.engine = engine;
        this.pack = pack;
    }

    @Override
    public void reported(Entity a, Result res) {
        if (a.group != null) hold(a, res);
        else associate(a, res);
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
        for (Entity b : engine.entities.values()) {
            if (b == a) continue;
            if (!pack.sameSourceAllow) {
                if (b.source.equals(a.source)) continue;
                if (b.group != null && groupHoldsSource(b.group, a.source)) continue;
            }
            boolean all = engine.runTests(pack.gate, "gate", a, b, res)
                    && engine.runTests(pack.confirm, "confirm", a, b, res);
            String pk = pairKey(a.key, b.key);
            long count = all ? counts.getOrDefault(pk, 0L) + 1 : 0;
            counts.put(pk, count);
            boolean ok = count >= pack.confirmCount;
            res.trace.add(Tests.rec("confirm", a, b, "count", count, pack.confirmCount, ok, false));
            if (ok) reached.add(b);
        }
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
        if (chosen == null) return;
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
        counts.put(pairKey(a.key, chosen.key), 0L);
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
            counts.keySet().removeIf(k -> {
                String[] ab = k.split("\\|", 2);
                return ab[0].equals(e.key) || ab[1].equals(e.key);
            });
            res.events.add(Records.ev("drop", "entity", e.key));
        }
        // 2. Fused output
        for (Map.Entry<String, TreeSet<String>> g : groups.entrySet()) {
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

    /** True when e beats the current primary; members are visited in key order so ties keep the earlier. */
    private boolean better(Entity e, Entity cur) {
        if (pack.outputLatest) return e.lastTime > cur.lastTime;
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
        return s;
    }

    private static String pairKey(String x, String y) {
        return KeyOrder.KEY_ORDER.compare(x, y) <= 0 ? x + "|" + y : y + "|" + x;
    }
}
