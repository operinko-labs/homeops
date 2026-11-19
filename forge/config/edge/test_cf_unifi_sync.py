"""Tests for cf-unifi-sync's safety guards: python -I forge/config/edge/test_cf_unifi_sync.py"""
import importlib.machinery
import importlib.util
import os
import sys
import unittest

sys.dont_write_bytecode = True  # no __pycache__ beside the deployed files

_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cf-unifi-sync")
_loader = importlib.machinery.SourceFileLoader("cf_unifi_sync", _path)
_spec = importlib.util.spec_from_loader("cf_unifi_sync", _loader)
sync = importlib.util.module_from_spec(_spec)
_loader.exec_module(sync)

HAVE = [f"104.{n}.0.0/16" for n in range(15)]


class CheckChange(unittest.TestCase):
    def test_adding_a_range_is_fine(self):
        sync.check_change(HAVE, HAVE + ["131.0.72.0/22"])

    def test_dropping_two_ranges_is_fine(self):
        sync.check_change(HAVE, HAVE[2:])

    def test_dropping_three_ranges_needs_force(self):
        with self.assertRaises(SystemExit):
            sync.check_change(HAVE, HAVE[3:])
        sync.check_change(HAVE, HAVE[3:], force=True)

    def test_shrinking_below_80_percent_needs_force(self):
        have = HAVE[:5]
        with self.assertRaises(SystemExit):
            sync.check_change(have, have[:3])  # 2 removals but 60%
        sync.check_change(have, have[:3], force=True)

    def test_too_wide_a_prefix_is_refused_even_with_force(self):
        for wide in ("0.0.0.0/0", "104.0.0.0/8", "96.0.0.0/11"):
            with self.assertRaises(SystemExit, msg=wide):
                sync.check_change(HAVE, HAVE + [wide], force=True)

    def test_slash_12_is_allowed(self):
        sync.check_change(HAVE, HAVE + ["96.0.0.0/12"])

    def test_first_fill_of_an_empty_group_is_fine(self):
        sync.check_change([], HAVE)


if __name__ == "__main__":
    unittest.main()
