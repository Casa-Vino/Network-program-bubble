"""Portable, dependency-free room-scan persistence and candidate plane fitting.

Experimental offline processing only; not wired into the Android Bubble app.
Coordinates are metres in one consistent scan reference frame.
"""
from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
import json
import math
import random

SCHEMA_VERSION = 1

def save_scan(path, points, metadata=None):
    """Atomically save raw XYZ points; never overwrite the input in processing."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {"schema_version": SCHEMA_VERSION, "units": "m",
            "metadata": metadata or {}, "points": [list(map(float, p)) for p in points]}
    if any(len(p) != 3 or not all(math.isfinite(x) for x in p) for p in data["points"]):
        raise ValueError("Every point must contain three finite coordinates")
    tmp = path.with_suffix(path.suffix + ".tmp")
    try:
        with tmp.open("w", encoding="utf-8") as f:
            json.dump(data, f, separators=(",", ":"))
            f.flush()
            import os
            os.fsync(f.fileno())
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)

def load_scan(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if data.get("schema_version") != SCHEMA_VERSION or data.get("units") != "m":
        raise ValueError("Unsupported scan format")
    points = data["points"]
    if any(len(p) != 3 or not all(isinstance(x, (int, float)) and math.isfinite(x) for x in p) for p in points):
        raise ValueError("Invalid points")
    return data

def voxel_sample(points, voxel=0.04):
    """Keep one representative per voxel for fitting; originals remain untouched."""
    if voxel <= 0:
        raise ValueError("voxel must be positive")
    buckets = {}
    for p in points:
        key = tuple(math.floor(v / voxel) for v in p)
        buckets.setdefault(key, p)
    return list(buckets.values())

def _plane(a, b, c):
    u = [b[i]-a[i] for i in range(3)]
    v = [c[i]-a[i] for i in range(3)]
    n = (u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0])
    length = math.sqrt(sum(x*x for x in n))
    if length < 1e-9:
        return None
    n = tuple(x/length for x in n)
    return n, -sum(n[i]*a[i] for i in range(3))

def fit_planes(points, threshold=0.035, min_inliers=80, iterations=300, max_planes=8, seed=0):
    """RANSAC candidate planes. Returns coefficients and inlier counts, NOT wall polygons.

    This does not infer boundaries, doorways, material or actual wall identity.
    """
    if threshold <= 0 or min_inliers < 3 or iterations < 1:
        raise ValueError("Invalid fitting parameters")
    remaining = list(voxel_sample(points))
    rng = random.Random(seed)
    found = []
    for _ in range(max_planes):
        if len(remaining) < min_inliers:
            break
        best = None
        best_ids = []
        for _ in range(iterations):
            a, b, c = rng.sample(remaining, 3)
            candidate = _plane(a, b, c)
            if candidate is None:
                continue
            n, d = candidate
            ids = [i for i,p in enumerate(remaining)
                   if abs(sum(n[j]*p[j] for j in range(3)) + d) <= threshold]
            if len(ids) > len(best_ids):
                best, best_ids = candidate, ids
        if best is None or len(best_ids) < min_inliers:
            break
        n, d = best
        found.append({"normal": list(n), "offset_m": d, "inlier_count": len(best_ids),
                      "candidate_type": "horizontal" if abs(n[2]) > .9 else
                                        "vertical" if abs(n[2]) < .2 else "oblique"})
        matched = set(best_ids)
        remaining = [p for i,p in enumerate(remaining) if i not in matched]
    return found
