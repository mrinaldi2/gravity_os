"""The file browser only serves what it should."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "companion"))

from gravity_files import FileBrowser, FileError  # noqa: E402


class FileBrowserTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = os.path.realpath(self.tmp.name)
        self.root = os.path.join(base, "root")
        self.outside = os.path.join(base, "outside")
        for folder in ("root/Projects/app", "root/.ssh", "root/.config/gh", "root/Library/Keychains", "outside"):
            os.makedirs(os.path.join(base, folder))
        for name in ("root/Projects/app/README.md", "root/.ssh/id_ed25519", "root/api.token",
                     "root/.hidden-note", "outside/secret.txt"):
            with open(os.path.join(base, name), "w") as handle:
                handle.write("x")
        os.symlink(self.outside, os.path.join(self.root, "escape"))
        self.files = FileBrowser([self.root])

    def tearDown(self):
        self.tmp.cleanup()

    def names(self, path, hidden=False):
        return [e["name"] for e in self.files.listing(path, hidden)["entries"]]

    def test_lists_folders_first_without_secrets(self):
        self.assertEqual(self.names(self.root), ["Library", "Projects"])
        self.assertEqual(self.names(self.root, hidden=True), [".config", "Library", "Projects", ".hidden-note"])

    def test_refuses_secret_places(self):
        for path in (".ssh/id_ed25519", ".ssh", "api.token", ".config/gh", "Library/Keychains"):
            with self.assertRaises(FileError, msg=path):
                self.files.resolve(os.path.join(self.root, path))

    def test_symlinks_cannot_escape(self):
        with self.assertRaises(FileError) as caught:
            self.files.open(os.path.join(self.root, "escape", "secret.txt"))
        self.assertEqual(caught.exception.code, "outside_roots")
        self.assertNotIn("escape", self.names(self.root))

    def test_dotdot_cannot_escape(self):
        with self.assertRaises(FileError):
            self.files.listing(os.path.join(self.root, "Projects", "..", ".."), False)

    def test_opens_a_file_and_knows_its_parent(self):
        path, kind, size = self.files.open(os.path.join(self.root, "Projects/app/README.md"))
        self.assertEqual((kind, size), ("text/markdown", 1))
        listing = self.files.listing(os.path.join(self.root, "Projects"), False)
        self.assertEqual(listing["parent"], self.files.display(self.root))
        self.assertIsNone(self.files.listing(self.root, False)["parent"])


if __name__ == "__main__":
    unittest.main()
