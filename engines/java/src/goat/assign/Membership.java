package goat.assign;

import goat.trace.Records;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;

/** correlate-assign.md, Memberships. */
/** One picture of the system tracks: members per track in creation order, and the counter. */
public final class Membership {
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
        events.add(Records.ev("leave", "system", s, "entity", key, "reason", reason));
        if (members.isEmpty()) {
            systems.remove(s);
            events.add(Records.ev("end", "system", s));
        }
    }

    Map<String, Object> systemsMap() {
        Map<String, Object> ss = new LinkedHashMap<>();
        for (Map.Entry<String, TreeSet<String>> s : systems.entrySet())
            ss.put(s.getKey(), new ArrayList<Object>(s.getValue()));
        return ss;
    }
}
