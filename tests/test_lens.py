"""Gravity Lens parses Claude Code logs into turns. Standard library only:

    python3 -m unittest discover tests
"""
import os
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "companion"))
sys.path.insert(0, os.path.join(ROOT, "demo"))

import gravity_lens  # noqa: E402
import make_demo  # noqa: E402


class LensTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.shots = os.path.join(self.tmp.name, "shots")
        os.makedirs(self.shots)
        for image in os.listdir(make_demo.ASSETS):
            with open(os.path.join(make_demo.ASSETS, image), "rb") as src, \
                    open(os.path.join(self.shots, image), "wb") as dst:
                dst.write(src.read())
        bots = {name: {"id": name, "workspace": ""} for _, members in make_demo.PROJECTS for name, _, _ in members}
        logs = make_demo.write_logs(bots, self.shots, {"Aurora Notes": os.path.join(self.tmp.name, "artifacts")})
        self.transcripts = {}
        for name, log in logs.items():
            folder = os.path.join(self.tmp.name, "logs", name)
            log.write(folder)
            transcript = gravity_lens.Transcript(folder)
            transcript.refresh()
            self.transcripts[name] = transcript

    def tearDown(self):
        self.tmp.cleanup()

    def test_turns_start_on_messages_and_typing(self):
        architect = self.transcripts["Architect"].turns
        self.assertEqual([t.trigger["kind"] for t in architect], ["typed", "message"])
        self.assertEqual(architect[1].trigger["from"], "You")

    def test_open_turn_and_current_step(self):
        ios = self.transcripts["iOS Dev"].turns[-1].summary(is_last=True)
        self.assertTrue(ios["open"])
        self.assertEqual(ios["current"], "Run the UI tests")
        self.assertEqual(ios["stats"]["edits"], 2)
        self.assertEqual((ios["stats"]["added"], ios["stats"]["removed"]), (8, 1))

    def test_finished_turn_outcome_and_errors(self):
        qa = self.transcripts["QA Tester"].turns[0].summary(is_last=False)
        self.assertFalse(qa["open"])
        self.assertEqual(qa["outcome"]["kind"], "completed")
        self.assertEqual(qa["stats"]["errors"], 1)

    def test_images_are_found(self):
        qa = self.transcripts["QA Tester"]
        kinds = sorted({ref["kind"] for e in qa.turns[0].events for ref in e.get("images", [])})
        self.assertEqual(kinds, ["file", "inline"])
        inline = next(i for i, entry in qa.images.items() if entry[0] == "inline")
        self.assertTrue(qa.images[inline][2])

    def test_envelopes(self):
        parsed = gravity_lens.parse_envelope("[msg #42 from PROJECT MANAGER · task · re #7] Ship it")
        self.assertEqual((parsed["from"], parsed["msg_kind"], parsed["num"], parsed["text"]),
                         ("Project Manager", "task", 42, "Ship it"))
        self.assertEqual(gravity_lens.parse_envelope("[msg #1 from USER · note] hi")["from"], "You")

    def test_names_keep_their_case(self):
        lens = gravity_lens.Lens("/nonexistent", "/nonexistent", "/nonexistent")
        fixed = lens.named({"from": "Ios Dev", "nested": [{"to": "Qa Tester"}]}, {"ios dev": "iOS Dev", "qa tester": "QA Tester"})
        self.assertEqual(fixed, {"from": "iOS Dev", "nested": [{"to": "QA Tester"}]})


if __name__ == "__main__":
    unittest.main()
