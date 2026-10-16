#!/usr/bin/env node
// Bundles the upstream JavaScript Alight runs in JavaScriptCore (Vane's tree
// fitter and Fieldbook's quota contract and pace math) into one committed
// file, so Swift builds never need Node and the logic is maintained only
// upstream.
//
//   node scripts/build-core.mjs           write Sources/Alight/Resources/alight-core.js
//   node scripts/build-core.mjs --check   fail if the committed bundle is stale
//
// Vane resolves from node_modules, or from VANE_DIST (a Vane checkout with a
// built dist/) while the published version is inside the npm cooldown.
// Fieldbook's quota closure (src/quota) is read with `git archive` at
// FIELDBOOK_COMMIT, so the pin holds whatever any checkout has checked out.
// The commit comes from FIELDBOOK_REPO or a sibling `fieldbook` checkout when
// one has it, otherwise it is fetched from Fieldbook's Nest origin into
// node_modules/.cache (FIELDBOOK_REMOTE overrides the URL).
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const output = join(root, "Sources/Alight/Resources/alight-core.js");
const check = process.argv.includes("--check");

const vaneDir = process.env.VANE_DIST
  ? resolve(process.env.VANE_DIST)
  : join(root, "node_modules/@owl-kestrel/vane");
if (!existsSync(join(vaneDir, "dist/src/index.js"))) {
  console.error(`build-core: no Vane build in ${vaneDir}; npm install it or set VANE_DIST`);
  process.exit(1);
}
const vane = JSON.parse(readFileSync(join(vaneDir, "package.json"), "utf8"));

// The Vane input is pinned by identity and by the digest of the JavaScript it
// contributes (dist/src/**/*.js, path and bytes, sorted): VANE_DIST or a
// differently built package cannot slip in other code under the same version.
const VANE_PIN = { name: "@owl-kestrel/vane", version: "0.1.0", jsDigest: "678dee02ed444100ef44810a6b265970592e02907a3e7dc3517406b4b8f86a01" };
function jsDigest(dir) {
  const files = [];
  (function walk(path) {
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      const full = join(path, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (full.endsWith(".js")) files.push(full);
    }
  })(dir);
  const hash = createHash("sha256");
  for (const file of files.sort()) {
    hash.update(relative(dir, file) + "\0");
    hash.update(readFileSync(file));
    hash.update("\0");
  }
  return hash.digest("hex");
}
const vaneDigest = jsDigest(join(vaneDir, "dist/src"));
if (vane.name !== VANE_PIN.name || vane.version !== VANE_PIN.version || vaneDigest !== VANE_PIN.jsDigest) {
  console.error(`build-core: Vane input ${vane.name}@${vane.version} (js ${vaneDigest}) is not the pinned ${VANE_PIN.name}@${VANE_PIN.version} (js ${VANE_PIN.jsDigest})`);
  process.exit(1);
}

// esbuild records each module's path in a comment, so both upstreams are
// staged at fixed paths: the bundle is identical whichever source fed it.
const stage = join(root, "node_modules/.cache/alight-core");
rmSync(stage, { recursive: true, force: true });
const vaneStage = join(stage, "vane");
mkdirSync(vaneStage, { recursive: true });
cpSync(join(vaneDir, "dist/src"), join(vaneStage, "dist/src"), { recursive: true });
const vaneEntry = join(vaneStage, "dist/src/index.js");

// Nest's owned Fieldbook main (`nest status fieldbook`).
const FIELDBOOK_COMMIT = "d914356d332b6078bf42c873c7488313000013ab";
const FIELDBOOK_REMOTE = process.env.FIELDBOOK_REMOTE ?? "ssh://git@5.161.252.182/srv/git/fieldbook.git";
const hasCommit = (path) => {
  try {
    return execFileSync("git", ["-C", path, "cat-file", "-t", FIELDBOOK_COMMIT], { stdio: ["ignore", "pipe", "ignore"] })
      .toString().trim() === "commit";
  } catch {
    return false;
  }
};
let fieldbookRepo = [process.env.FIELDBOOK_REPO, join(root, "../fieldbook"), join(root, "../../fieldbook")]
  .filter(Boolean)
  .map((path) => resolve(path))
  .find(hasCommit);
if (!fieldbookRepo) {
  fieldbookRepo = join(root, "node_modules/.cache/alight-fieldbook.git");
  if (!hasCommit(fieldbookRepo)) {
    if (!existsSync(fieldbookRepo)) execFileSync("git", ["init", "--bare", "--quiet", fieldbookRepo]);
    console.log(`build-core: fetching Fieldbook ${FIELDBOOK_COMMIT.slice(0, 7)} from ${FIELDBOOK_REMOTE}`);
    execFileSync("git", ["-C", fieldbookRepo, "fetch", "--quiet", "--depth=1", FIELDBOOK_REMOTE, FIELDBOOK_COMMIT], { stdio: "inherit" });
  }
  if (!hasCommit(fieldbookRepo)) {
    console.error(`build-core: Fieldbook ${FIELDBOOK_COMMIT} unavailable; set FIELDBOOK_REPO or FIELDBOOK_REMOTE`);
    process.exit(1);
  }
}
const fieldbookDir = join(stage, "fieldbook");
mkdirSync(fieldbookDir, { recursive: true });
const archive = execFileSync("git", ["-C", fieldbookRepo, "archive", "--format=tar", FIELDBOOK_COMMIT, "package.json", "src/quota"]);
execFileSync("tar", ["-x", "-C", fieldbookDir], { input: archive });
const fieldbook = JSON.parse(readFileSync(join(fieldbookDir, "package.json"), "utf8"));

const result = await build({
  entryPoints: [join(root, "js/entry.mjs")],
  bundle: true,
  write: false,
  format: "iife",
  globalName: "AlightCore",
  platform: "neutral",
  target: "es2022",
  legalComments: "none",
  alias: {
    "@owl-kestrel/vane": vaneEntry,
    "@owl-kestrel/fieldbook/quota/alight-snapshot": join(fieldbookDir, "src/quota/alight-snapshot.mjs"),
    "@owl-kestrel/fieldbook/quota": join(fieldbookDir, "src/quota/index.mjs"),
    "node:crypto": join(root, "js/shims/node-crypto.mjs"),
  },
  inject: [join(root, "js/shims/buffer.mjs")],
  banner: {
    js: `// Generated by scripts/build-core.mjs from ${vane.name}@${vane.version} and ` +
      `${fieldbook.name}@${FIELDBOOK_COMMIT.slice(0, 7)} (src/quota). Do not edit.`,
  },
});
const bundle = result.outputFiles[0].text;

if (check) {
  const committed = existsSync(output) ? readFileSync(output, "utf8") : "";
  if (committed !== bundle) {
    console.error("build-core: Sources/Alight/Resources/alight-core.js is stale; run npm run build:core");
    process.exit(1);
  }
  console.log("build-core: bundle is current");
} else {
  writeFileSync(output, bundle);
  console.log(`build-core: wrote ${output} (${bundle.length} bytes, ${vane.name}@${vane.version}, ${fieldbook.name}@${FIELDBOOK_COMMIT.slice(0, 7)})`);
}
