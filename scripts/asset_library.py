"""Local, content-addressed asset library for Worldsmith source and runtime files.

SQLite holds searchable metadata; large files live as immutable blobs beside it.
This is intentionally separate from per-scene assets and does not mutate scenes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LIBRARY = ROOT / "data" / "library"
KINDS = {"mesh", "texture", "scene_source", "material", "splat_source", "splat_cleaned"}
ORIGINS = {"authored", "generated", "external", "captured", "imported"}


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


class AssetLibrary:
    def __init__(self, root: Path = DEFAULT_LIBRARY):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / "blobs").mkdir(exist_ok=True)
        self.database = sqlite3.connect(self.root / "library.sqlite3")
        self.database.row_factory = sqlite3.Row
        self.database.execute("PRAGMA foreign_keys = ON")
        self.database.executescript("""
            CREATE TABLE IF NOT EXISTS versions (
                asset_id TEXT NOT NULL,
                sha256 TEXT NOT NULL,
                kind TEXT NOT NULL,
                origin TEXT NOT NULL,
                license TEXT NOT NULL,
                source TEXT NOT NULL,
                blob_name TEXT NOT NULL,
                metadata_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (asset_id, sha256)
            );
            CREATE TABLE IF NOT EXISTS current_versions (
                asset_id TEXT PRIMARY KEY,
                sha256 TEXT NOT NULL,
                FOREIGN KEY (asset_id, sha256) REFERENCES versions(asset_id, sha256)
            );
            CREATE INDEX IF NOT EXISTS versions_kind ON versions(kind);
            CREATE INDEX IF NOT EXISTS versions_origin ON versions(origin);
        """)

    def register(self, asset_id: str, path: Path, kind: str, origin: str,
                 license_name: str, source: str = "", metadata: dict | None = None,
                 promote: bool = True) -> dict:
        if not asset_id or len(asset_id) > 64 or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789_-" for c in asset_id):
            raise ValueError("Asset ID must use lowercase letters, digits, underscore, or hyphen")
        if kind not in KINDS or origin not in ORIGINS or not license_name:
            raise ValueError("Invalid kind, origin, or license")
        if origin == "external" and not source:
            raise ValueError("External assets need a source URL or attribution")
        path = path.resolve(strict=True)
        if not path.is_file():
            raise ValueError("Asset source must be a file")
        checksum = digest(path)
        blob_name = f"{checksum}{path.suffix.lower()}"
        blob = self.root / "blobs" / blob_name
        if not blob.exists():
            temporary = blob.with_name(blob.name + ".part")
            shutil.copyfile(path, temporary)
            if digest(temporary) != checksum:
                temporary.unlink()
                raise OSError("Asset changed during registration")
            temporary.replace(blob)
        if digest(blob) != checksum:
            raise OSError("Stored asset hash mismatch")
        metadata_json = json.dumps(metadata or {}, sort_keys=True, separators=(",", ":"))
        with self.database:
            self.database.execute("""
                INSERT OR IGNORE INTO versions
                (asset_id, sha256, kind, origin, license, source, blob_name, metadata_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, (asset_id, checksum, kind, origin, license_name, source, blob_name, metadata_json))
            if promote:
                self.database.execute("""
                    INSERT INTO current_versions(asset_id, sha256) VALUES (?, ?)
                    ON CONFLICT(asset_id) DO UPDATE SET sha256=excluded.sha256
                """, (asset_id, checksum))
        return self.version(asset_id, checksum)

    def version(self, asset_id: str, checksum: str) -> dict:
        row = self.database.execute("""
            SELECT * FROM versions WHERE asset_id=? AND sha256=?
        """, (asset_id, checksum)).fetchone()
        if row is None:
            raise KeyError((asset_id, checksum))
        result = dict(row)
        result["metadata"] = json.loads(result.pop("metadata_json"))
        result["blob"] = str(self.root / "blobs" / result.pop("blob_name"))
        return result

    def promote(self, asset_id: str, checksum: str) -> dict:
        self.version(asset_id, checksum)
        with self.database:
            self.database.execute("""
                INSERT INTO current_versions(asset_id, sha256) VALUES (?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET sha256=excluded.sha256
            """, (asset_id, checksum))
        return self.get(asset_id)

    def get(self, asset_id: str) -> dict:
        row = self.database.execute("""
            SELECT v.* FROM versions v JOIN current_versions c
              ON c.asset_id=v.asset_id AND c.sha256=v.sha256
            WHERE v.asset_id=?
        """, (asset_id,)).fetchone()
        if row is None:
            raise KeyError(asset_id)
        result = dict(row)
        result["metadata"] = json.loads(result.pop("metadata_json"))
        result["blob"] = str(self.root / "blobs" / result.pop("blob_name"))
        return result

    def list(self) -> list[dict]:
        ids = self.database.execute("SELECT asset_id FROM current_versions ORDER BY asset_id").fetchall()
        return [self.get(row[0]) for row in ids]

    def verify(self, asset_id: str) -> bool:
        item = self.get(asset_id)
        return digest(Path(item["blob"])) == item["sha256"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_LIBRARY)
    commands = parser.add_subparsers(dest="command", required=True)
    register = commands.add_parser("register")
    register.add_argument("asset_id")
    register.add_argument("path", type=Path)
    register.add_argument("--kind", choices=sorted(KINDS), required=True)
    register.add_argument("--origin", choices=sorted(ORIGINS), required=True)
    register.add_argument("--license", required=True)
    register.add_argument("--source", default="")
    register.add_argument("--metadata", default="{}")
    register.add_argument("--candidate", action="store_true", help="Store a version without making it current")
    commands.add_parser("list")
    promote = commands.add_parser("promote")
    promote.add_argument("asset_id")
    promote.add_argument("sha256")
    verify = commands.add_parser("verify")
    verify.add_argument("asset_id")
    args = parser.parse_args()
    library = AssetLibrary(args.root)
    if args.command == "register":
        result = library.register(args.asset_id, args.path, args.kind, args.origin,
                                  args.license, args.source, json.loads(args.metadata),
                                  promote=not args.candidate)
    elif args.command == "promote":
        result = library.promote(args.asset_id, args.sha256)
    elif args.command == "verify":
        result = {"asset_id": args.asset_id, "valid": library.verify(args.asset_id)}
    else:
        result = library.list()
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
