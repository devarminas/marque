import { readFileSync, readdirSync } from "node:fs";
import { join, basename } from "node:path";

function mat4Identity() { return [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]; }
function mat4Mul(a, b) {
  const o = new Array(16).fill(0);
  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++)
    for (let k = 0; k < 4; k++) o[c*4+r] += a[k*4+r] * b[c*4+k];
  return o;
}
function nodeLocal(n) {
  if (n.matrix) return n.matrix;
  const t = n.translation ?? [0,0,0], q = n.rotation ?? [0,0,0,1], s = n.scale ?? [1,1,1];
  const [x,y,z,w] = q;
  const m = [
    (1-2*(y*y+z*z))*s[0], (2*(x*y+z*w))*s[0], (2*(x*z-y*w))*s[0], 0,
    (2*(x*y-z*w))*s[1], (1-2*(x*x+z*z))*s[1], (2*(y*z+x*w))*s[1], 0,
    (2*(x*z+y*w))*s[2], (2*(y*z-x*w))*s[2], (1-2*(x*x+y*y))*s[2], 0,
    t[0], t[1], t[2], 1,
  ];
  return m;
}
function xform(m, p) {
  return [
    m[0]*p[0]+m[4]*p[1]+m[8]*p[2]+m[12],
    m[1]*p[0]+m[5]*p[1]+m[9]*p[2]+m[13],
    m[2]*p[0]+m[6]*p[1]+m[10]*p[2]+m[14],
  ];
}
function bounds(file) {
  const g = JSON.parse(readFileSync(file, "utf8"));
  let lo = [Infinity,Infinity,Infinity], hi = [-Infinity,-Infinity,-Infinity];
  const visit = (idx, parent) => {
    const n = g.nodes[idx];
    const m = mat4Mul(parent, nodeLocal(n));
    if (n.mesh !== undefined) for (const prim of g.meshes[n.mesh].primitives) {
      const acc = g.accessors[prim.attributes.POSITION];
      for (const cx of [acc.min[0], acc.max[0]]) for (const cy of [acc.min[1], acc.max[1]]) for (const cz of [acc.min[2], acc.max[2]]) {
        const p = xform(m, [cx,cy,cz]);
        for (let i = 0; i < 3; i++) { lo[i] = Math.min(lo[i], p[i]); hi[i] = Math.max(hi[i], p[i]); }
      }
    }
    for (const c of n.children ?? []) visit(c, m);
  };
  for (const root of g.scenes[g.scene ?? 0].nodes) visit(root, mat4Identity());
  const images = (g.images ?? []).map(i => i.uri).filter(Boolean);
  return { lo, hi, images };
}
const dir = process.argv[2];
const f = v => v.toFixed(2).padStart(6);
console.log("name | minX maxX | minY maxY | minZ maxZ | sizeX sizeY sizeZ | images");
for (const name of readdirSync(dir).filter(n => n.endsWith(".gltf")).sort()) {
  const { lo, hi, images } = bounds(join(dir, name));
  console.log(`${basename(name, ".gltf")} | ${f(lo[0])} ${f(hi[0])} | ${f(lo[1])} ${f(hi[1])} | ${f(lo[2])} ${f(hi[2])} | ${f(hi[0]-lo[0])} ${f(hi[1]-lo[1])} ${f(hi[2]-lo[2])} | ${images.join(",")}`);
}
