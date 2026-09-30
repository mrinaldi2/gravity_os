"""The autostart script rewrites only the bind line, and only when needed."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "companion"))

import gravity_autostart as auto  # noqa: E402

TOML = """# Gravity daemon configuration
home = "/tmp/x"

# Bind addresses.
bind = ["127.0.0.1", "100.101.102.103"]
port = 49777
"""


class AutostartTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "gravityd.toml")
        with open(self.path, "w") as handle:
            handle.write(TOML)

    def tearDown(self):
        self.tmp.cleanup()

    def read(self):
        with open(self.path) as handle:
            return handle.read()

    def test_same_address_changes_nothing(self):
        self.assertFalse(auto.update_bind(self.path, "100.101.102.103"))
        self.assertEqual(self.read(), TOML)
        self.assertFalse(os.path.exists(self.path + ".bak-autostart"))

    def test_new_address_replaces_the_old_one_only(self):
        self.assertTrue(auto.update_bind(self.path, "100.64.1.2"))
        text = self.read()
        self.assertIn('bind = ["127.0.0.1", "100.64.1.2"]', text)
        self.assertNotIn("100.101.102.103", text)
        self.assertEqual(text.replace('"100.64.1.2"', '"100.101.102.103"'), TOML)
        with open(self.path + ".bak-autostart") as handle:
            self.assertEqual(handle.read(), TOML)

    def test_keeps_other_addresses_and_never_binds_everything(self):
        self.assertEqual(auto.desired_binds(["192.168.1.5", "0.0.0.0", "100.70.0.1"], "100.80.0.2"),
                         ["127.0.0.1", "192.168.1.5", "100.80.0.2"])

    def test_adds_a_bind_line_when_missing(self):
        with open(self.path, "w") as handle:
            handle.write("port = 49777\n")
        self.assertTrue(auto.update_bind(self.path, "100.64.9.9"))
        self.assertTrue(self.read().startswith('bind = ["127.0.0.1", "100.64.9.9"]\n'))


if __name__ == "__main__":
    unittest.main()
