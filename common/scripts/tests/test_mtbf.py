# test_mtbf.py — self-test for mtbf.py: settling time per stage count, the MTBF formula on a
# case worked by hand, the no-slack case, and the human-readable units. Run:
#   python3 -m unittest discover -s common/scripts/tests   (also part of `make vplan`)

import math
import sys
import unittest
from pathlib import Path

# Import the script from the directory above this one.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mtbf  # noqa: E402


# Each test checks one rule of the model.
class TestMtbf(unittest.TestCase):
    # One stage loses the logic delay; n stages get n-1 clean periods.
    def test_settling(self):
        self.assertEqual(mtbf.settling_ps(1, 1000, 100, 600), 300)
        self.assertEqual(mtbf.settling_ps(2, 1000, 100, 600), 900)
        self.assertEqual(mtbf.settling_ps(3, 1000, 100, 600), 1800)
        with self.assertRaises(ValueError):
            mtbf.settling_ps(0, 1000, 100, 600)

    # By hand: 2 stages at 1 GHz, f_data 1 GHz, tau 20 ps, T_W 50 ps, t_pd 100 ps:
    # S = 900 ps, e^45 / (50e-12 * 1e9 * 1e9) = 3.49e19 / 5e7 = 6.98e11 s (about 22,000 years).
    def test_formula(self):
        lg = mtbf.log10_mtbf_s(2, 1e9, 1e9, 20, 50, 100, 600)
        self.assertAlmostEqual(lg, 45 * math.log10(math.e) - math.log10(5e7), places=9)
        self.assertAlmostEqual(10 ** lg, 6.98e11, delta=0.01e11)
        self.assertEqual(mtbf.human(lg), "2.21e+04 years")

    # No settling time left: MTBF is zero, shown as such.
    def test_no_slack(self):
        lg = mtbf.log10_mtbf_s(1, 1e9, 1e9, 20, 50, 100, 900)
        self.assertEqual(lg, -math.inf)
        self.assertEqual(mtbf.human(lg), "0 (no settling time)")

    # Units switch from seconds to hours to years.
    def test_units(self):
        self.assertEqual(mtbf.human(math.log10(5)), "5 s")
        self.assertEqual(mtbf.human(math.log10(7200)), "2 h")
        self.assertTrue(mtbf.human(20).endswith("years"))


if __name__ == "__main__":
    unittest.main()
