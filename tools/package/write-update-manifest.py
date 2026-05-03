#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib


def sha256(path):
    h = hashlib.sha256()
    with pathlib.Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Write Termplex update manifest")
    parser.add_argument("--version", required=True)
    parser.add_argument("--channel", default="stable", choices=("stable", "tip"))
    parser.add_argument("--released-at", required=True)
    parser.add_argument("--notes-url", required=True)
    parser.add_argument("--asset", action="append", default=[], help="KEY=URL=PATH")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    downloads = {}
    for item in args.asset:
        key, url, path = item.split("=", 2)
        downloads[key] = {"url": url, "sha256": sha256(path)}

    payload = {
        "version": args.version,
        "channel": args.channel,
        "released_at": args.released_at,
        "notes_url": args.notes_url,
        "downloads": downloads,
    }
    pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
