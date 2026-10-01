"""The parts of Gravity Lens that differ on Windows, checked from any system:

    python3 -m unittest discover tests
"""
import os
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "companion"))

import gravity_lens  # noqa: E402


class WindowsTests(unittest.TestCase):
    def test_image_paths_with_drive_letters(self):
        text = r"Saved C:\Users\me\shots\home.png, then D:/work/a.JPG and /Users/me/b.webp."
        self.assertEqual(gravity_lens.IMAGE_PATH.findall(text),
                         [r"C:\Users\me\shots\home.png", "D:/work/a.JPG", "/Users/me/b.webp"])

    def test_project_folder_uses_claude_codes_windows_name(self):
        workspace = r"C:\Users\me\.gravity\projects\Aurora\bots\ann\workspace"
        with tempfile.TemporaryDirectory() as projects, mock.patch.object(gravity_lens, "WINDOWS", True):
            expected = os.path.join(projects, "C--Users-me--gravity-projects-Aurora-bots-ann-workspace")
            # Before the first log exists, the Windows name is the guess.
            self.assertEqual(gravity_lens.project_folder(projects, workspace), expected)
            os.makedirs(expected)
            self.assertEqual(gravity_lens.project_folder(projects, workspace), expected)

    def test_project_folder_keeps_the_mac_name(self):
        workspace = "/Users/me/.gravity/projects/Aurora Notes/bots/ann/workspace"
        with tempfile.TemporaryDirectory() as projects, mock.patch.object(gravity_lens, "WINDOWS", False):
            self.assertEqual(gravity_lens.project_folder(projects, workspace),
                             os.path.join(projects, "-Users-me--gravity-projects-Aurora Notes-bots-ann-workspace"))
            # A newer Claude Code that replaces the space too is found as well.
            loose = os.path.join(projects, "-Users-me--gravity-projects-Aurora-Notes-bots-ann-workspace")
            os.makedirs(loose)
            self.assertEqual(gravity_lens.project_folder(projects, workspace), loose)

    def test_paths_reach_the_phone_with_forward_slashes(self):
        with mock.patch.object(gravity_lens, "WINDOWS", True):
            self.assertEqual(gravity_lens.portable(r"~\Documents\notes.md"), "~/Documents/notes.md")

    def test_windows_thumbnails_use_powershell_without_a_window(self):
        with mock.patch.object(gravity_lens, "WINDOWS", True):
            command = gravity_lens.thumbnail_command(r"C:\a b\shot.png", r"C:\cache\x.jpg")
        self.assertEqual(command["args"][0], "powershell.exe")
        # Paths go through the environment, never into the script text.
        self.assertEqual(command["env"]["LENS_SRC"], r"C:\a b\shot.png")
        self.assertEqual(command["env"]["LENS_DST"], r"C:\cache\x.jpg")
        self.assertNotIn("a b", command["args"][-1])
        self.assertEqual(command["creationflags"], 0x08000000)

    def test_mac_thumbnails_still_use_sips(self):
        with mock.patch.object(gravity_lens, "WINDOWS", False):
            command = gravity_lens.thumbnail_command("/x/a.png", "/c/a.jpg")
        self.assertEqual(command["args"][0], "/usr/bin/sips")
        self.assertNotIn("env", command)



@unittest.skipUnless(os.name == "nt", "needs Windows")
class OnWindowsTests(unittest.TestCase):
    def setUp(self):
        from gravity_files import FileBrowser
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(os.path.realpath(self.tmp.name), "root")
        for folder in ("Projects\\app", "AppData\\Roaming\\Browser"):
            os.makedirs(os.path.join(self.root, folder))
        with open(os.path.join(self.root, "Projects", "app", "README.md"), "w") as handle:
            handle.write("x")
        self.files = FileBrowser([self.root])

    def tearDown(self):
        self.tmp.cleanup()

    def test_file_browser_paths_use_forward_slashes(self):
        listing = self.files.listing(os.path.join(self.root, "Projects"), False)
        self.assertNotIn("\\", listing["absolute"])
        self.assertTrue(all("\\" not in entry["path"] for entry in listing["entries"]))
        # A path the phone sends back with "/" still opens.
        path, kind, _ = self.files.open(listing["absolute"] + "/app/README.md")
        self.assertEqual(kind, "text/markdown")

    def test_appdata_is_never_shared_in_any_case(self):
        from gravity_files import FileError
        for name in ("AppData", "APPDATA\\Roaming", "appdata/Roaming/Browser"):
            with self.assertRaises(FileError, msg=name):
                self.files.resolve(os.path.join(self.root, name))
        self.assertNotIn("AppData", [e["name"] for e in self.files.listing(self.root, True)["entries"]])

    def test_displays_have_the_phone_s_fields(self):
        rows = gravity_lens.displays()
        self.assertIsInstance(rows, list)
        for row in rows:
            self.assertTrue({"id", "main", "x", "y", "width", "height"} <= set(row))

    def test_thumbnail_through_powershell(self):
        sys.path.insert(0, os.path.join(ROOT, "demo"))
        import make_demo
        source = os.path.join(make_demo.ASSETS, sorted(n for n in os.listdir(make_demo.ASSETS) if n.endswith(".png"))[0])
        with tempfile.TemporaryDirectory() as cache, mock.patch.object(gravity_lens, "THUMB_DIR", cache):
            small = gravity_lens.thumbnail(source)
            self.assertIsNotNone(small)
            with open(small, "rb") as handle:
                self.assertEqual(handle.read(3), b"\xff\xd8\xff")  # a JPEG


if __name__ == "__main__":
    unittest.main()
