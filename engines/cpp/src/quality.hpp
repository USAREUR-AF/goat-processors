// The quality engine: spec/quality.md, version 0.2.
//
// Quality measures every entity and every source from the reports alone and
// applies the actions a pack's rules attach to those measures. It reuses the
// correlate frame and filter (track.hpp) and the JSON value (json.hpp).
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "json.hpp"
#include "track.hpp"
#include "pack.hpp"

namespace corr::quality {

// ---- Pack (spec "Pack", "Rules") ------------------------------------------

enum class Scope { Entity, Source };
enum class Op { Lt, Le, Gt, Ge };
enum class Action { Mark, Downgrade, Drop, Alert };

struct Rule {
    std::string name;
    Scope scope = Scope::Entity;
    std::string measure;
    Op op = Op::Gt;
    double limit = 0;
    std::int64_t for_count = 1;
    double clear = 0;
    Action action = Action::Alert;
    double factor = 1;          // downgrade only
};

struct Pack {
    std::string name;
    std::string version;
    FilterParams filter;        // accel_var, default_ce_m, vel_sigma_ms, unknown_vel_ms
    std::int64_t window_ms = 0;
    std::int64_t min_samples = 0;
    std::int64_t forget_ms = 0;
    std::map<std::string, TimeDefault> time_default;   // by source id (spec "Reports", "Time quality")
    std::vector<Rule> rules;    // pack order
};

// Parses the text of a pack.def; throws corr::PackError on any load error.
Pack parse_pack(const std::string& text);

// Reads <dir>/pack.def; throws corr::PackError.
Pack load_pack(const std::string& dir);

// The measures tables, in table order (spec "Entity measures", "Source measures").
const std::vector<std::string>& entity_measure_names();
const std::vector<std::string>& source_measure_names();

const char* scope_name(Scope s);
const char* action_name(Action a);

// ---- Engine ----------------------------------------------------------------

// Spec "Samples": one accepted report, as kept in its entity's window.
struct Record {
    std::int64_t wt = 0;
    std::int64_t time_ms = 0;
    std::string order;                      // first, advance, duplicate, out-of-order
    std::optional<std::int64_t> interval;
    std::optional<std::int64_t> latency;
    Json lateness;                          // null when not taken; an integer, or a binary64 when the clock is a mean of two
    bool source_out_of_order = false;       // the source_order sample is out-of-order
    std::optional<double> time_error;       // ms, stated by the report or the pack's time_default
    std::optional<std::string> time_state;  // coherent, drifting, free-running; absent when unstated
    std::optional<double> nis;
    std::optional<double> speed_err;
    bool ce = false, vel = false, hae = false;
};

struct Entity {
    std::string source;                     // track.source_id of its first report
    std::int64_t last = 0;                  // latest accepted time (`last`)
    Point last_pos{0, 0};              // plane position of its latest first/advance report
    Filter filter;
    std::vector<Record> window;             // arrival order
};

// Spec "Rules": per rule, per subject.
struct RuleState {
    std::int64_t count = 0;
    bool active = false;
};

// The events and trace one call returns.
struct Output {
    Json events = Json::make_array();
    Json trace = Json::make_array();
};

class Engine {
public:
    explicit Engine(Pack pack);

    Output ingest(const Json& report);
    Output tick(std::int64_t now_ms);
    Json snapshot() const;

private:
    // Spec "Entity measures" and "Source measures": an object, one key per measure.
    Json entity_measures(const Entity& e, std::int64_t now_ms) const;
    Json source_measures(const std::vector<const Json*>& entity_measures) const;

    // Spec "Rules", Evaluation, for every rule of `scope` on one subject.
    void evaluate_rules(Scope scope, const std::string& subject, const Json& measures, Output& out);

    // Spec "Tick" steps 2 and 3: end the active rules of `scope` for a subject and drop its states.
    void forget_subject(Scope scope, const std::string& subject, Output& out);

    // Spec "Forwarding": the pass event for an accepted report.
    Json pass_event(const Json& report, const std::string& key, const std::string& source) const;

    bool in_force(size_t rule_index, const std::string& key, const std::string& source) const;

    // Spec "Input clock": the median of the other sources' latest times, and
    // the source latest of `source`, from the entities as they are now.
    std::optional<Json> input_clock(const std::string& source) const;
    std::optional<std::int64_t> source_latest(const std::string& source) const;

    Pack pack_;
    std::optional<std::pair<double, double>> ref_;     // lat0, lon0
    std::optional<std::int64_t> last_tick_;
    std::map<std::string, Entity> entities_;           // key order
    std::vector<std::map<std::string, RuleState>> rule_states_;   // per rule in pack order, subject in key order
};

} // namespace corr::quality
