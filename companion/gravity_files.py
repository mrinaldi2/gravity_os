"""File browsing for Gravity Lens: list folders and fetch files under chosen roots.

Off unless configured. Every path is resolved (symlinks included) and must
stay inside a root; places that hold secrets are refused even inside a root.
Serving needs the device's `control` grant, not just `read`.
"""
from __future__ import annotations

import mimetypes
import os
import time
from typing import Any, Dict, Iterable, List, Optional, Tuple

# Refused wherever they appear under a root.
DENIED_DIRS = {
    ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".password-store", ".config/gh",
    "Keychains", "Cookies", "secrets", ".Trash",
}
DENIED_NAMES = {".netrc", ".credentials.json", ".git-credentials", ".npmrc", ".pypirc", "client.token"}
DENIED_SUFFIXES = (".token", ".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".kdbx")

FILE_LIMIT = 200_000_000

# Older Pythons do not know these; the phone previews by type.
for _ext, _type in {".md": "text/markdown", ".markdown": "text/markdown", ".swift": "text/x-swift",
                    ".py": "text/x-python", ".ts": "text/plain", ".tsx": "text/plain", ".rs": "text/plain",
                    ".go": "text/plain", ".cs": "text/plain", ".toml": "text/plain", ".yaml": "text/plain",
                    ".yml": "text/plain", ".log": "text/plain", ".jsonl": "text/plain", ".sh": "text/x-sh",
                    ".webp": "image/webp", ".heic": "image/heic"}.items():
    mimetypes.add_type(_type, _ext)


class FileError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


class FileBrowser:
    def __init__(self, roots: Iterable[str]):
        self.roots = [os.path.realpath(os.path.expanduser(root)) for root in roots]
        self.home = os.path.expanduser("~")

    # Paths -----------------------------------------------------------------

    def display(self, path: str) -> str:
        if path == self.home:
            return "~"
        return "~" + path[len(self.home):] if path.startswith(self.home + os.sep) else path

    def resolve(self, raw: str) -> str:
        """An absolute, symlink-free path inside a root, or FileError."""
        if not raw or raw == "~":
            raw = self.roots[0] if self.roots else self.home
        if "\x00" in raw:
            raise FileError(400, "invalid", "Invalid path.")
        path = os.path.realpath(os.path.expanduser(raw))
        root = next((r for r in self.roots if path == r or path.startswith(r.rstrip(os.sep) + os.sep)), None)
        if root is None:
            raise FileError(403, "outside_roots", "That folder is not shared with the phone.")
        relative = os.path.relpath(path, root)
        parts = [] if relative == "." else relative.split(os.sep)
        joined = "/".join(parts)
        if any(p in DENIED_DIRS for p in parts) or any(f"/{d}/" in f"/{joined}/" for d in DENIED_DIRS if "/" in d):
            raise FileError(403, "denied", "That location holds secrets and is never shared.")
        name = parts[-1] if parts else ""
        if name in DENIED_NAMES or name.lower().endswith(DENIED_SUFFIXES):
            raise FileError(403, "denied", "That file holds secrets and is never shared.")
        return path

    def parent(self, path: str) -> Optional[str]:
        if path in self.roots:
            return None
        parent = os.path.dirname(path)
        try:
            return self.display(self.resolve(parent))
        except FileError:
            return None

    # Views -----------------------------------------------------------------

    def listing(self, raw: str, hidden: bool) -> Dict[str, Any]:
        path = self.resolve(raw)
        if not os.path.isdir(path):
            raise FileError(404, "not_a_folder", "Not a folder.")
        try:
            names = os.listdir(path)
        except PermissionError:
            raise FileError(403, "blocked_by_macos",
                            "macOS blocked Gravity Lens from this folder. Allow it on the Mac in "
                            "System Settings → Privacy & Security → Files and Folders → Gravity Lens, "
                            "or add Gravity Lens to Full Disk Access.")
        entries: List[Dict[str, Any]] = []
        for name in names:
            if not hidden and name.startswith("."):
                continue
            full = os.path.join(path, name)
            try:
                self.resolve(full)
            except FileError:
                continue
            try:
                st = os.stat(full)
            except OSError:
                continue
            is_dir = os.path.isdir(full)
            entries.append({
                "name": name,
                "path": self.display(os.path.join(path, name)),
                "kind": "folder" if is_dir else "file",
                "link": os.path.islink(full),
                "size": 0 if is_dir else st.st_size,
                "modified_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime)),
                "type": "" if is_dir else (mimetypes.guess_type(name)[0] or ""),
            })
        entries.sort(key=lambda e: (e["kind"] != "folder", e["name"].lower()))
        return {
            "path": self.display(path),
            "absolute": path,
            "name": os.path.basename(path) or path,
            "parent": self.parent(path),
            "roots": [self.display(r) for r in self.roots],
            "entries": entries,
        }

    def open(self, raw: str) -> Tuple[str, str, int]:
        """(absolute path, media type, size) of a file that may be sent."""
        path = self.resolve(raw)
        if not os.path.isfile(path):
            raise FileError(404, "not_a_file", "Not a file.")
        size = os.path.getsize(path)
        if size > FILE_LIMIT:
            raise FileError(413, "too_large", "Files over 200 MB are not sent to the phone.")
        if not os.access(path, os.R_OK):
            raise FileError(403, "blocked_by_macos", "macOS blocked Gravity Lens from reading this file.")
        return path, mimetypes.guess_type(path)[0] or "application/octet-stream", size
