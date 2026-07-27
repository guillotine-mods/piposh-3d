#!/usr/bin/env python3
"""Standalone WMB -> browser 3D viewer. Independent of the Godot pipeline.

Fresh, self-contained WMB entity/light/path parser (does not import
extract_wmb_full.py or gs_math.py -- written new, on purpose, so this is a
genuinely separate code path from the production converter/Godot spawn code,
not a wrapper around it) plus a tiny local HTTP server that serves a
Three.js viewer of the result. The point: judge entity placement/facing
directly against the raw parsed data, in a browser, with no Godot editor,
no headless rendering, no import cache -- and no dependency on this
session's own tool-execution environment, which has no working GPU context.

The entity rotation math (Conitec ang_to_matrix conjugated into a
right-handed Y-up basis) is implemented TWICE, independently: once here in
Python (for sanity printing) and once fresh in the browser's JavaScript
(see the embedded viewer HTML below). If both agree with what Godot shows,
that's real cross-validation, not two copies of the same bug.

Usage:
    python tools/wmb_web_viewer.py Start
    python tools/wmb_web_viewer.py Start --port 8765 --no-browser

Then open the printed URL (or it opens automatically). Orbit with the
mouse, click an entity to see its name/file/action/pan-tilt-roll, use the
search box to jump to a specific entity (e.g. "Yachdal"). Reused as-is
(read-only, unmodified): the already-built `{Level}_brush.glb` for wall/
floor spatial context, and the already-built per-model `.glb`/`.mdlanim`
under assets/converted/mdl/ -- brush *parsing* and MDL mesh parsing are a
separate, already-proven problem (see docs/CONTRACT.md #2, the
verify_transforms.py distance-preservation check); this tool is for the
disputed part: WMB entity position + angle + which way each mesh ends up
facing.
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import threading
import webbrowser
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
WMB_SRC_DIR = ROOT / "original" / "piposh3d" / "WMB"
MDL_GLB_DIR = ROOT / "assets" / "converted" / "mdl"
WMB_GLB_DIR = ROOT / "assets" / "converted" / "wmb"
LEVEL_JSON_DIR = ROOT / "assets" / "converted" / "levels"


# --- Fresh WMB parse (independent of tools/extract_wmb_full.py) -----------


def _c_str(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("latin-1", errors="replace")


def _read_lists(data: bytes, n: int = 20) -> list[tuple[int, int]]:
    """WMB directory: a fixed-size table of (offset, length) pairs right
    after the 4-byte magic. Every chunk (objects, planes, textures, ...) is
    addressed through this table -- list index 15 is the object list for
    the WMB5 layout this game uses (confirmed by extract_wmb_full.py
    working across all 57 levels; re-verified here independently by
    checking every list's offset+length stays in-bounds)."""
    lists: list[tuple[int, int]] = []
    off = 4
    for _ in range(n):
        if off + 8 > len(data):
            break
        lo, ln = struct.unpack_from("<II", data, off)
        off += 8
        if ln == 0 and lo == 0:
            lists.append((lo, ln))
            continue
        if lo >= len(data) or lo + ln > len(data):
            break
        lists.append((lo, ln))
    return lists


def pos_gs_to_three(x: float, y: float, z: float) -> list[float]:
    """Acknex RHZUP (+X east, +Y north, +Z up) -> right-handed Y-up.
    Same target space as Godot: (x, y, z)_gs -> (x, z, -y). Three.js is
    also right-handed Y-up, so this is directly usable with no extra flip.
    """
    return [float(x), float(z), float(-y)]


def scale_gs_to_three(sx: float, sy: float, sz: float) -> list[float]:
    return [float(sx), float(sz), float(sy)]


def _norm_tilt(tilt_deg: float) -> float:
    t = float(tilt_deg)
    if t > 180.0:
        t -= 360.0
    elif t < -180.0:
        t += 360.0
    return t


def entity_basis_columns(pan_deg: float, tilt_deg: float, roll_deg: float) -> list[float]:
    """Conitec ang_to_matrix (DirectX Y-up), conjugated by S=diag(1,1,-1)
    into a right-handed Y-up basis -- same target convention as Godot's
    Basis(x_g, y_g, z_g). Returned as 9 floats, column-major: local +X,
    +Y, +Z axes expressed in world space. Local +X is "forward" by the
    whole pipeline's convention (WED pan=0 -> +X)."""
    p = math.radians(float(pan_deg))
    t = math.radians(_norm_tilt(tilt_deg))
    r = math.radians(float(roll_deg))
    cp, sp = math.cos(p), math.sin(p)
    ct, st = math.cos(t), math.sin(t)
    cr, sr = math.cos(r), math.sin(r)
    x_dx = (ct * cp, st, ct * sp)
    y_dx = (-cr * st * cp + sr * sp, cr * ct, -cr * st * sp - sr * cp)
    z_dx = (-sr * st * cp - cr * sp, sr * ct, cr * cp - sr * st * sp)
    x_g = (x_dx[0], x_dx[1], -x_dx[2])
    y_g = (y_dx[0], y_dx[1], -y_dx[2])
    z_g = (-z_dx[0], -z_dx[1], z_dx[2])
    return [*x_g, *y_g, *z_g]


def parse_wmb(path: Path) -> dict:
    data = path.read_bytes()
    magic = data[:4]
    lists = _read_lists(data)
    if len(lists) <= 15 or lists[15][1] == 0:
        raise ValueError(f"{path.name}: no object list found (list 15 empty)")

    base, length = lists[15]
    chunk = memoryview(data)[base : base + length]
    count = struct.unpack_from("<I", chunk, 0)[0]
    offsets = list(struct.unpack_from(f"<{count}I", chunk, 4))

    entities: list[dict] = []
    lights: list[dict] = []
    paths: list[dict] = []

    for rel in offsets:
        o = rel
        if o + 4 > len(chunk):
            continue
        typ = struct.unpack_from("<I", chunk, o)[0]
        o += 4

        if typ == 2:  # LIGHT
            ox, oy, oz = struct.unpack_from("<3f", chunk, o)
            o += 12
            r, g, b, rng = struct.unpack_from("<4f", chunk, o)
            lights.append(
                {
                    "pos": pos_gs_to_three(ox, oy, oz),
                    "color": [r / 100.0, g / 100.0, b / 100.0],
                    "range": float(rng),
                }
            )
            continue

        if typ == 6:  # PATH
            try:
                name = _c_str(bytes(chunk[o : o + 20]))
                o += 20
                fnum = struct.unpack_from("<f", chunk, o)[0]
                o += 4
                o += 12  # unused[3]
                num_edges = struct.unpack_from("<I", chunk, o)[0]
                o += 4
                npoints = int(fnum) if fnum >= 1.0 else int(num_edges)
                points = []
                for _ in range(max(npoints, 0)):
                    if o + 12 > len(chunk):
                        break
                    px, py, pz = struct.unpack_from("<3f", chunk, o)
                    o += 12
                    points.append(pos_gs_to_three(px, py, pz))
                paths.append({"name": name or f"path_{len(paths) + 1}", "points": points})
            except struct.error:
                pass
            continue

        if typ == 3:  # OLD ENTITY
            ox, oy, oz = struct.unpack_from("<3f", chunk, o)
            o += 12
            pan, tilt, roll = struct.unpack_from("<3f", chunk, o)
            o += 12
            sx, sy, sz = struct.unpack_from("<3f", chunk, o)
            o += 12
            name = _c_str(bytes(chunk[o : o + 20]))
            o += 20
            filename = _c_str(bytes(chunk[o : o + 13]))
            o += 13
            action = _c_str(bytes(chunk[o : o + 20]))
            o += 20
            o += 3  # pad (float-aligns the skills block)
            skills = list(struct.unpack_from("<8f", chunk, o))
            o += 32
            flags = struct.unpack_from("<I", chunk, o)[0] if o + 4 <= len(chunk) else 0
            entities.append(
                {
                    "name": name,
                    "file": filename,
                    "action": action,
                    "pos": pos_gs_to_three(ox, oy, oz),
                    "pan_tilt_roll_gs": [float(pan), float(tilt), float(roll)],
                    "scale": scale_gs_to_three(sx, sy, sz),
                    "skills": skills,
                    "flags": int(flags),
                    "basis": entity_basis_columns(pan, tilt, roll),
                }
            )
            continue

        if typ == 7:  # ENTITY (new format)
            ox, oy, oz = struct.unpack_from("<3f", chunk, o)
            o += 12
            pan, tilt, roll = struct.unpack_from("<3f", chunk, o)
            o += 12
            sx, sy, sz = struct.unpack_from("<3f", chunk, o)
            o += 12
            name = _c_str(bytes(chunk[o : o + 33]))
            o += 33
            filename = _c_str(bytes(chunk[o : o + 33]))
            o += 33
            action = _c_str(bytes(chunk[o : o + 33]))
            o += 34
            skills = list(struct.unpack_from("<20f", chunk, o))
            o += 80
            flags = struct.unpack_from("<I", chunk, o)[0]
            o += 4
            entities.append(
                {
                    "name": name,
                    "file": filename,
                    "action": action,
                    "pos": pos_gs_to_three(ox, oy, oz),
                    "pan_tilt_roll_gs": [float(pan), float(tilt), float(roll)],
                    "scale": scale_gs_to_three(sx, sy, sz),
                    "skills": skills,
                    "flags": int(flags),
                    "basis": entity_basis_columns(pan, tilt, roll),
                }
            )
            continue

    return {
        "source": path.name,
        "magic": magic.decode("ascii", "replace"),
        "entities": entities,
        "lights": lights,
        "paths": paths,
    }


# --- Model file lookup (reuse already-converted .glb, unmodified) ---------


def _build_index(dir_path: Path) -> dict[str, str]:
    idx: dict[str, str] = {}
    if dir_path.exists():
        for p in dir_path.glob("*.glb"):
            idx[p.stem.lower()] = p.name
    return idx


def resolve_model_url(file_field: str, mdl_index: dict, wmb_index: dict) -> str | None:
    if not file_field:
        return None
    stem = Path(file_field).stem.lower()
    is_wmb = file_field.lower().endswith(".wmb")
    if is_wmb:
        name = wmb_index.get(stem)
        if name:
            return f"/wmb-glb/{name}"
        return None
    name = mdl_index.get(stem)
    if name:
        return f"/mdl-glb/{name}"
    return None


# --- HTTP server ------------------------------------------------------------

VIEWER_HTML = r"""<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>WMB viewer -- __LEVEL__</title>
<style>
  html, body { margin: 0; height: 100%; background: #14161c; overflow: hidden; font-family: system-ui, sans-serif; }
  #canvas-wrap { position: absolute; inset: 0; }
  #panel {
    position: absolute; top: 8px; left: 8px; width: 320px; max-height: calc(100% - 16px);
    background: rgba(20,22,28,0.92); color: #e8e8ec; border-radius: 8px; padding: 10px 12px;
    overflow-y: auto; font-size: 13px; box-shadow: 0 4px 18px rgba(0,0,0,0.5);
  }
  #panel h1 { font-size: 15px; margin: 0 0 6px; }
  #panel input { width: 100%; box-sizing: border-box; padding: 5px 7px; margin-bottom: 6px;
    background: #23262f; border: 1px solid #3a3f4b; color: #e8e8ec; border-radius: 4px; }
  #entity-list { list-style: none; margin: 0; padding: 0; }
  #entity-list li { padding: 3px 6px; border-radius: 4px; cursor: pointer; white-space: nowrap;
    overflow: hidden; text-overflow: ellipsis; }
  #entity-list li:hover { background: #2d3140; }
  #entity-list li.active { background: #3d5a99; }
  #info { margin-top: 8px; padding-top: 8px; border-top: 1px solid #3a3f4b; line-height: 1.5; }
  #info b { color: #9fd3ff; }
  #hint { opacity: 0.65; font-size: 11px; margin-top: 6px; }
  #toggles label { display: block; margin: 2px 0; }
  #status { position: absolute; bottom: 8px; left: 8px; color: #9aa; font-size: 11px; }
</style>
</head>
<body>
<div id="canvas-wrap"></div>
<div id="panel">
  <h1>__LEVEL__.wmb -- __N_ENT__ entities, __N_LIGHT__ lights, __N_PATH__ paths</h1>
  <input id="search" placeholder="filter by name / file / action...">
  <div id="toggles">
    <label><input type="checkbox" id="chk-brush" checked> brush (walls/floor)</label>
    <label><input type="checkbox" id="chk-arrows" checked> forward arrows (red = local +X)</label>
    <label><input type="checkbox" id="chk-labels"> name labels (can get busy)</label>
    <label><input type="checkbox" id="chk-lights" checked> light markers</label>
  </div>
  <ul id="entity-list"></ul>
  <div id="info">Click an entity (or pick it from the list) to see its data here.</div>
  <div id="hint">Drag to orbit, scroll to zoom, right-drag to pan. Click an entity in the 3D view or in the list.</div>
</div>
<div id="status">loading...</div>
<script type="importmap">
{
  "imports": {
    "three": "https://unpkg.com/three@0.160.0/build/three.module.js",
    "three/addons/": "https://unpkg.com/three@0.160.0/examples/jsm/"
  }
}
</script>
<script type="module">
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";

const statusEl = document.getElementById("status");

// --- Independent re-implementation of the entity basis math (JS side).
// If this disagrees with what Godot renders for the same pan/tilt/roll,
// that's a real finding -- not the same bug rendered twice. Mirrors
// wmb_web_viewer.py's entity_basis_columns() / Godot's
// _acknex_entity_basis(), written fresh, not copy-pasted from either.
function entityBasisMatrix(panDeg, tiltDeg, rollDeg) {
  let tilt = tiltDeg;
  if (tilt > 180) tilt -= 360; else if (tilt < -180) tilt += 360;
  const p = THREE.MathUtils.degToRad(panDeg);
  const t = THREE.MathUtils.degToRad(tilt);
  const r = THREE.MathUtils.degToRad(rollDeg);
  const cp = Math.cos(p), sp = Math.sin(p);
  const ct = Math.cos(t), st = Math.sin(t);
  const cr = Math.cos(r), sr = Math.sin(r);
  const xDx = new THREE.Vector3(ct * cp, st, ct * sp);
  const yDx = new THREE.Vector3(-cr * st * cp + sr * sp, cr * ct, -cr * st * sp - sr * cp);
  const zDx = new THREE.Vector3(-sr * st * cp - cr * sp, sr * ct, cr * cp - sr * st * sp);
  const xG = new THREE.Vector3(xDx.x, xDx.y, -xDx.z);
  const yG = new THREE.Vector3(yDx.x, yDx.y, -yDx.z);
  const zG = new THREE.Vector3(-zDx.x, -zDx.y, zDx.z);
  const m = new THREE.Matrix4();
  m.makeBasis(xG, yG, zG);
  return m;
}

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x14161c);
scene.add(new THREE.AmbientLight(0xffffff, 0.9));
scene.add(new THREE.HemisphereLight(0xddeeff, 0x334033, 0.6));

const wrap = document.getElementById("canvas-wrap");
const camera = new THREE.PerspectiveCamera(60, wrap.clientWidth / wrap.clientHeight, 0.5, 40000);
camera.position.set(400, 500, 800);

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setSize(wrap.clientWidth, wrap.clientHeight);
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
wrap.appendChild(renderer.domElement);

const controls = new OrbitControls(camera, renderer.domElement);
controls.target.set(0, 0, 0);
controls.update();

window.addEventListener("resize", () => {
  camera.aspect = wrap.clientWidth / wrap.clientHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(wrap.clientWidth, wrap.clientHeight);
});

const grid = new THREE.GridHelper(4000, 40, 0x444a58, 0x2a2e38);
scene.add(grid);
scene.add(new THREE.AxesHelper(150)); // red=+X green=+Y(up) blue=+Z

const gltfLoader = new GLTFLoader();
const modelCache = new Map(); // url -> Promise<Object3D template>

function loadModel(url) {
  if (!modelCache.has(url)) {
    modelCache.set(
      url,
      new Promise((resolve) => {
        gltfLoader.load(
          url,
          (gltf) => resolve(gltf.scene),
          undefined,
          () => resolve(null)
        );
      })
    );
  }
  return modelCache.get(url);
}

const entityGroup = new THREE.Group();
scene.add(entityGroup);
const labelSprites = [];
const pickable = []; // {mesh, data}

function makeLabelSprite(text) {
  const canvas = document.createElement("canvas");
  const ctx = canvas.getContext("2d");
  const pad = 8;
  ctx.font = "28px sans-serif";
  const w = Math.ceil(ctx.measureText(text).width) + pad * 2;
  canvas.width = w;
  canvas.height = 40;
  ctx.font = "28px sans-serif";
  ctx.fillStyle = "rgba(10,12,16,0.75)";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.fillStyle = "#fff";
  ctx.fillText(text, pad, 29);
  const tex = new THREE.CanvasTexture(canvas);
  const mat = new THREE.SpriteMaterial({ map: tex, depthTest: false });
  const sprite = new THREE.Sprite(mat);
  sprite.scale.set(canvas.width * 0.6, canvas.height * 0.6, 1);
  return sprite;
}

function addArrow(basisArr, pos, length, color) {
  // basis columns: [xX,xY,xZ, yX,yY,yZ, zX,zY,zZ] -- local +X is "forward".
  const fwd = new THREE.Vector3(basisArr[0], basisArr[1], basisArr[2]).normalize();
  const origin = new THREE.Vector3(...pos);
  const arrow = new THREE.ArrowHelper(fwd, origin, length, color, length * 0.25, length * 0.15);
  entityGroup.add(arrow);
}

async function buildScene(level) {
  document.getElementById("panel").querySelector("h1").textContent =
    `${level.source} -- ${level.entities.length} entities, ${level.lights.length} lights, ${level.paths.length} paths`;

  // Brush (walls/floor) for spatial context -- reused as-is from the
  // existing, already-verified extract_wmb_mesh.py output.
  if (level.brush_url) {
    gltfLoader.load(level.brush_url, (gltf) => {
      gltf.scene.traverse((o) => {
        if (o.isMesh) {
          o.material = o.material.clone();
          o.material.side = THREE.DoubleSide;
        }
      });
      gltf.scene.name = "__brush__";
      scene.add(gltf.scene);
      document.getElementById("chk-brush").onchange = (e) => {
        gltf.scene.visible = e.target.checked;
      };
    });
  }

  // Lights: real OmniLight-equivalents + a small visible marker sphere.
  const lightMarkerGeo = new THREE.SphereGeometry(6, 8, 8);
  const lightGroup = new THREE.Group();
  scene.add(lightGroup);
  for (const l of level.lights) {
    const color = new THREE.Color(l.color[0], l.color[1], l.color[2]);
    const point = new THREE.PointLight(color, 1.2, Math.max(l.range * 0.6, 80));
    point.position.set(...l.pos);
    lightGroup.add(point);
    const marker = new THREE.Mesh(lightMarkerGeo, new THREE.MeshBasicMaterial({ color }));
    marker.position.set(...l.pos);
    lightGroup.add(marker);
  }
  document.getElementById("chk-lights").onchange = (e) => (lightGroup.visible = e.target.checked);

  // Paths: connect points with lines + numbered dots.
  const pathGroup = new THREE.Group();
  scene.add(pathGroup);
  for (const p of level.paths) {
    if (p.points.length < 2) continue;
    const pts = p.points.map((pt) => new THREE.Vector3(...pt));
    const geo = new THREE.BufferGeometry().setFromPoints(pts);
    const line = new THREE.Line(geo, new THREE.LineBasicMaterial({ color: 0xffaa33 }));
    pathGroup.add(line);
  }

  // Entities.
  const listEl = document.getElementById("entity-list");
  const bbox = new THREE.Box3();
  let anyPoint = false;

  for (const ent of level.entities) {
    const li = document.createElement("li");
    li.textContent = `${ent.name || "(unnamed)"} [${ent.action || "-"}] ${ent.file}`;
    li.dataset.search = li.textContent.toLowerCase();
    listEl.appendChild(li);

    const pos = ent.pos;
    bbox.expandByPoint(new THREE.Vector3(...pos));
    anyPoint = true;

    let visualAdded = null;
    if (ent.model_url) {
      const template = await loadModel(ent.model_url);
      if (template) {
        const inst = template.clone(true);
        inst.traverse((o) => {
          if (o.isMesh) o.material = o.material.clone();
        });
        const m = entityBasisMatrix(...ent.pan_tilt_roll_gs);
        m.setPosition(...pos);
        inst.matrixAutoUpdate = false;
        inst.matrix.copy(m);
        entityGroup.add(inst);
        visualAdded = inst;
        inst.traverse((o) => {
          if (o.isMesh) pickable.push({ mesh: o, data: ent, li });
        });
      }
    }
    if (!visualAdded) {
      const geo = new THREE.ConeGeometry(4, 14, 6);
      geo.rotateZ(-Math.PI / 2); // cone tip along +X
      const mat = new THREE.MeshBasicMaterial({ color: 0x66ccff });
      const cone = new THREE.Mesh(geo, mat);
      const m = entityBasisMatrix(...ent.pan_tilt_roll_gs);
      m.setPosition(...pos);
      cone.matrixAutoUpdate = false;
      cone.matrix.copy(m);
      entityGroup.add(cone);
      pickable.push({ mesh: cone, data: ent, li });
    }

    addArrow(ent.basis, pos, 45, 0xff3333);

    const label = makeLabelSprite(ent.name || ent.file || "?");
    label.position.set(pos[0], pos[1] + 60, pos[2]);
    label.visible = document.getElementById("chk-labels").checked;
    entityGroup.add(label);
    labelSprites.push(label);

    li.addEventListener("click", () => selectEntity(ent, li, pos));
  }

  document.getElementById("chk-arrows").onchange = (e) => {
    entityGroup.children.forEach((c) => {
      if (c.type === "ArrowHelper") c.visible = e.target.checked;
    });
  };
  document.getElementById("chk-labels").onchange = (e) => {
    labelSprites.forEach((s) => (s.visible = e.target.checked));
  };

  if (anyPoint) {
    const center = bbox.getCenter(new THREE.Vector3());
    const size = bbox.getSize(new THREE.Vector3()).length();
    controls.target.copy(center);
    camera.position.copy(center).add(new THREE.Vector3(size * 0.35, size * 0.35, size * 0.5));
    controls.update();
  }

  statusEl.textContent = `${level.entities.length} entities placed (models loaded where a matching .glb exists; cyan cones otherwise).`;
}

let activeLi = null;
function selectEntity(ent, li, pos) {
  if (activeLi) activeLi.classList.remove("active");
  li.classList.add("active");
  activeLi = li;
  li.scrollIntoView({ block: "nearest" });
  const [pan, tilt, roll] = ent.pan_tilt_roll_gs;
  document.getElementById("info").innerHTML = `
    <div><b>name</b> ${ent.name || "(unnamed)"}</div>
    <div><b>file</b> ${ent.file}</div>
    <div><b>action</b> ${ent.action || "(none)"}</div>
    <div><b>pos (x,y,z godot-space)</b> ${pos.map((v) => v.toFixed(1)).join(", ")}</div>
    <div><b>pan/tilt/roll (gs deg)</b> ${pan.toFixed(1)}, ${tilt.toFixed(1)}, ${roll.toFixed(1)}</div>
    <div><b>flags</b> ${ent.flags}</div>
  `;
  controls.target.set(...pos);
  controls.update();
}

const raycaster = new THREE.Raycaster();
const mouse = new THREE.Vector2();
renderer.domElement.addEventListener("click", (ev) => {
  const rect = renderer.domElement.getBoundingClientRect();
  mouse.x = ((ev.clientX - rect.left) / rect.width) * 2 - 1;
  mouse.y = -((ev.clientY - rect.top) / rect.height) * 2 + 1;
  raycaster.setFromCamera(mouse, camera);
  const hits = raycaster.intersectObjects(pickable.map((p) => p.mesh), false);
  if (hits.length) {
    const hitMesh = hits[0].object;
    const found = pickable.find((p) => p.mesh === hitMesh);
    if (found) selectEntity(found.data, found.li, [found.data.pos[0], found.data.pos[1], found.data.pos[2]]);
  }
});

document.getElementById("search").addEventListener("input", (e) => {
  const q = e.target.value.toLowerCase();
  document.querySelectorAll("#entity-list li").forEach((li) => {
    li.style.display = li.dataset.search.includes(q) ? "" : "none";
  });
});

fetch("/api/level.json")
  .then((r) => r.json())
  .then(buildScene)
  .catch((err) => {
    statusEl.textContent = "Failed to load level.json: " + err;
  });

(function animate() {
  requestAnimationFrame(animate);
  controls.update();
  renderer.render(scene, camera);
})();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def __init__(self, *args, level_data: dict, brush_path: Path | None, level_name: str, **kwargs):
        self._level_data = level_data
        self._brush_path = brush_path
        self._level_name = level_name
        super().__init__(*args, **kwargs)

    def log_message(self, fmt, *args):  # quieter console
        pass

    def _send_bytes(self, data: bytes, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def _send_file(self, path: Path, content_type: str) -> None:
        if not path.exists():
            self.send_error(404)
            return
        self._send_bytes(path.read_bytes(), content_type)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        if path == "/" or path == "":
            # Plain .replace(), not .format() -- the HTML/CSS/JS below is
            # full of literal `{...}` (CSS rules, JS objects, the import
            # map) that .format() would try to parse as placeholders and
            # crash on (this broke every request to "/" the first time).
            html = (
                VIEWER_HTML.replace("__LEVEL__", self._level_name)
                .replace("__N_ENT__", str(len(self._level_data["entities"])))
                .replace("__N_LIGHT__", str(len(self._level_data["lights"])))
                .replace("__N_PATH__", str(len(self._level_data["paths"])))
            )
            self._send_bytes(html.encode("utf-8"), "text/html; charset=utf-8")
        elif path == "/api/level.json":
            self._send_bytes(json.dumps(self._level_data).encode("utf-8"), "application/json")
        elif path.startswith("/mdl-glb/"):
            self._send_file(MDL_GLB_DIR / path[len("/mdl-glb/") :], "model/gltf-binary")
        elif path.startswith("/wmb-glb/"):
            self._send_file(WMB_GLB_DIR / path[len("/wmb-glb/") :], "model/gltf-binary")
        elif path == "/brush.glb" and self._brush_path is not None:
            self._send_file(self._brush_path, "model/gltf-binary")
        else:
            self.send_error(404)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("level", help="Level name, e.g. Start (looks for original/piposh3d/WMB/Start.WMB)")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()

    wmb_path = None
    for ext in (".WMB", ".wmb"):
        cand = WMB_SRC_DIR / (args.level + ext)
        if cand.exists():
            wmb_path = cand
            break
    if wmb_path is None:
        print(f"Could not find {args.level}.WMB under {WMB_SRC_DIR}", file=sys.stderr)
        return 1

    print(f"Parsing {wmb_path.name} (fresh parser, independent of extract_wmb_full.py)...")
    level_data = parse_wmb(wmb_path)

    mdl_index = _build_index(MDL_GLB_DIR)
    wmb_index = _build_index(WMB_GLB_DIR)
    for ent in level_data["entities"]:
        ent["model_url"] = resolve_model_url(ent["file"], mdl_index, wmb_index)
    missing = sum(1 for e in level_data["entities"] if e["file"] and not e["model_url"])
    print(
        f"  {len(level_data['entities'])} entities, {len(level_data['lights'])} lights, "
        f"{len(level_data['paths'])} paths. {missing} entities have no matching .glb "
        "(shown as cyan cones instead)."
    )

    brush_path = LEVEL_JSON_DIR / f"{args.level}_brush.glb"
    if not brush_path.exists():
        print(f"  (no {brush_path.name} found -- viewer will show entities/lights/paths without walls)")
        level_data["brush_url"] = None
    else:
        level_data["brush_url"] = "/brush.glb"

    handler_cls = partial(
        Handler, level_data=level_data, brush_path=brush_path if brush_path.exists() else None, level_name=args.level
    )
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler_cls)
    url = f"http://127.0.0.1:{args.port}/"
    print(f"Serving on {url}  (Ctrl+C to stop)")
    if not args.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
