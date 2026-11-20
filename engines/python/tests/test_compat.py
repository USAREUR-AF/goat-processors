"""The packages goat_correlator, goat_filter, goat_fuse and goat_quality
keep every name they exported before the goat_core layout (tools import
them)."""

import unittest
import importlib

OLD = {
    "goat_correlator": "AssignEngine Engine Pack PackError load_pack make_engine",
    "goat_correlator.engine": "R TESTS FILTER_PARAMS MANEUVER_PARAMS MODELS BIAS_PARAMS TIME_STATES REQUIRED "
                              "OPTIONAL _is _normalize PackError Pack _params _num _int parse_pack load_pack "
                              "_wrap180 _predict_axis _pos_step _vel_step _pos_update _vel_update _blend "
                              "_transition _Entity _env _filter_snap Engine INF min_cost_assignment "
                              "assignment_total _choice_vector _constrained _order_key _first_assignment "
                              "ranked_assignments _Members _Record _History AssignEngine make_engine",
    "goat_filter": "Engine Pack PackError load_pack make_engine parse_pack",
    "goat_filter.engine": "REQUIRED _is _normalize R INT_MAX NUMBER INTEGER SINGLE ACTIONS RANGE_SETS PARAMS "
                          "PackError _number _integer _lat _lon _list _token _vertices Condition Rule Pack "
                          "_condition parse_pack load_pack rad deg wrap distance polygon predict environment "
                          "affiliation _is_number key_equal _in_range Engine make_engine",
    "goat_fuse": "Engine Pack PackError load_pack parse_pack",
    "goat_fuse.engine": "REQUIRED _CorrelateEngine _is _normalize _pos_update _predict_axis _vel_update "
                        "FILTER_PARAMS METHODS RULES ONCE NUMBER INTEGER PackError Pack _num parse_pack "
                        "load_pack _group_of _usable _same ci_weight ci_fold inverse_variance _Entity Engine",
    "goat_quality": "Engine Pack PackError load_pack parse_pack",
    "goat_quality.engine": "R _predict_axis _pos_update _vel_update _wrap180 FILTER_PARAMS WINDOW_PARAMS "
                           "RULE_PARAMS REQUIRED MEASURES TIME_STATES TIME_CODE ENTITY_MEASURES SOURCE_MEASURES "
                           "OPS ACTIONS NUM_RE INT_RE NAME_RE CONTROL_RE SEP_RE MAX_FINITE _is PackError Rule "
                           "Pack _num _int _params parse_pack load_pack _Entity _mean _median _met Engine",
}


class Compat(unittest.TestCase):
    def test_old_names(self):
        for mod, names in OLD.items():
            m = importlib.import_module(mod)
            for n in names.split():
                with self.subTest(name=mod + "." + n):
                    self.assertTrue(hasattr(m, n))

    def test_old_shapes(self):
        q = importlib.import_module("goat_quality.engine")
        self.assertEqual(q.MEASURES[0], ("reports", "sum"))
        self.assertEqual(q.SOURCE_MEASURES[-1], "entities")
        f = importlib.import_module("goat_fuse.engine")
        self.assertEqual(f.METHODS, ("inverse_variance", "covariance_intersection", "best", "priority", "latest"))
        fl = importlib.import_module("goat_filter.engine")
        self.assertIn({"name", "eq"}, fl.PARAMS["key"])

    def test_one_error_class(self):
        import goat_correlator, goat_filter, goat_fuse, goat_quality
        self.assertIs(goat_correlator.PackError, goat_filter.PackError)
        self.assertIs(goat_fuse.PackError, goat_quality.PackError)


if __name__ == "__main__":
    unittest.main()
