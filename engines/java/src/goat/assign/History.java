package goat.assign;

import java.util.ArrayList;
import java.util.List;

/** correlate-assign.md, Window: the histories of pending ticks. */
/** A list of pending ticks, oldest first. */
final class History {
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
