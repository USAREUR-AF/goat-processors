package goat.assign;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** One pending tick of a history. Never changed once a later record or a copy exists. */
final class Record {
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
