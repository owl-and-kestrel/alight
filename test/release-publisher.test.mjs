import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { execFile, execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import test from "node:test";
import { GLIDESLOPE_BRIDGE, buildBridgePayload, signManifestPayload } from "../scripts/release-manifest.mjs";

const execFileAsync = promisify(execFile);
const root = path.resolve(new URL("..", import.meta.url).pathname);
const pkg = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));

// The Alight release commit must descend from the pinned bridge commit, so the
// fixtures use this checkout's HEAD (alight main history).
const sourceCommit = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const preBridgeCommit = execFileSync("git", ["-C", root, "rev-parse", `${GLIDESLOPE_BRIDGE.sourceCommit}^`], { encoding: "utf8" }).trim();

async function bridgeFixture(directory, { mutate = (value) => value, signingKey = null } = {}) {
  const bridgeDir = path.join(directory, "bridge");
  await mkdir(bridgeDir, { recursive: true });
  const zip = Buffer.from("bridge fixture wrapping Glideslope.app", "utf8");
  const zipSha = createHash("sha256").update(zip).digest("hex");
  const { version, build } = GLIDESLOPE_BRIDGE;
  const artifactURL = `https://updates.owlandkestrel.com/glideslope/releases/v${version}/${zipSha}/Glideslope.zip`;
  const appcast = Buffer.from(`<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:shortVersionString>${version}</sparkle:shortVersionString><sparkle:version>${build}</sparkle:version><enclosure url="${artifactURL}" length="${zip.length}" sparkle:edSignature="fixture-signature" /></item></channel></rss>`, "utf8");
  const appcastSha = createHash("sha256").update(appcast).digest("hex");
  const manifest = mutate(buildBridgePayload({
    version, build, channel: "stable", publishedAt: new Date().toISOString().replace(/\.\d+Z$/u, "Z"),
    downloadPageUrl: "https://owlandkestrel.com/apps/alight",
    feedUrl: "https://updates.owlandkestrel.com/glideslope/stable/appcast.xml", feedSha256: appcastSha,
    sourceCommit: GLIDESLOPE_BRIDGE.sourceCommit, sourceDirty: false, buildConfiguration: "release", architectures: "arm64",
    artifactUrl: artifactURL, artifactSha256: zipSha, artifactSizeBytes: zip.length
  }));
  const document = signingKey ? signManifestPayload(manifest, signingKey) : manifest;
  await writeFile(path.join(bridgeDir, "Glideslope.zip"), zip);
  await writeFile(path.join(bridgeDir, "appcast.xml"), appcast);
  await writeFile(path.join(bridgeDir, "glideslope-bridge.json"), `${JSON.stringify(document)}\n`);
  return { zipSha };
}

async function fixture({ dirty = false, signed = false, mutate = (value) => value, alightCommit = sourceCommit } = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "alight-publisher-"));
  const zip = Buffer.from("signed update fixture", "utf8");
  const zipSha = createHash("sha256").update(zip).digest("hex");
  const artifactURL = `https://updates.owlandkestrel.com/alight/releases/v${pkg.version}/${zipSha}/Alight.zip`;
  const appcast = Buffer.from(`<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:shortVersionString>${pkg.version}</sparkle:shortVersionString><sparkle:version>${pkg.build}</sparkle:version><enclosure url="${artifactURL}" length="${zip.length}" sparkle:edSignature="fixture-signature" /></item></channel></rss>`, "utf8");
  const appcastSha = createHash("sha256").update(appcast).digest("hex");
  let payload = {
    schema: "ok.product-update.v1", appId: "alight", bundleId: "com.owlandkestrel.alight",
    version: pkg.version, build: pkg.build, channel: "stable", publishedAt: new Date().toISOString(), downloadPageUrl: "https://owlandkestrel.com/apps/alight",
    updateFeed: { format: "sparkle.appcast.v2", url: "https://updates.owlandkestrel.com/alight/stable/appcast.xml", sha256: appcastSha },
    source: { repository: "https://github.com/owl-and-kestrel/alight.git", commit: alightCommit, dirty, buildConfiguration: "release" },
    artifacts: [{ platform: "macos", kind: "archive", url: artifactURL, sha256: zipSha, sizeBytes: zip.length }]
  };
  payload = mutate(structuredClone(payload));
  let document = payload;
  let publicKeyPath = "";
  let keys = null;
  if (signed) {
    const bytes = Buffer.from(`${JSON.stringify(payload, null, 2)}\n`);
    keys = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    document = { schema: "ok.signed-manifest.v1", publisher: { id: "owl-kestrel", domain: "owlandkestrel.com", keyId: "ok-release-p256-v1" },
      signedPayload: bytes.toString("base64url"), signature: { alg: "ECDSA_P256_SHA256_DER", value: sign("sha256", bytes, keys.privateKey).toString("base64url") } };
    publicKeyPath = path.join(directory, "key.pem");
    await writeFile(publicKeyPath, keys.publicKey.export({ type: "spki", format: "pem" }));
  }
  await writeFile(path.join(directory, "Alight.zip"), zip);
  await writeFile(path.join(directory, "appcast.xml"), appcast);
  await writeFile(path.join(directory, "alight-update.json"), `${JSON.stringify(document)}\n`);
  return { directory, publicKeyPath, privateKey: keys?.privateKey ?? null };
}

async function run(directory, extra = [], env = {}) {
  return execFileAsync(process.execPath, ["scripts/publish-release.mjs", ...extra], { cwd: root,
    env: { ...process.env, ALIGHT_RELEASE_DIR: directory, ...env } });
}

test("dry-run validates the content-addressed ZIP and appcast without leaking credentials", async () => {
  const f = await fixture();
  try {
    const { stdout } = await run(f.directory, [], { ALIGHT_OK_API_KEY: "secret-one", ALIGHT_CHIRP_API_KEY: "secret-two" });
    const plan = JSON.parse(stdout);
    assert.equal(plan.mode, "dry-run");
    assert.equal(plan.publicationAuthority, "nest-owned-release-origin");
    assert.equal(plan.publicationStatus, "frozen-pending-authenticated-nest-client");
    assert.equal(plan.build, pkg.build);
    assert.match(plan.artifactKey, new RegExp(`/v${pkg.version}/[0-9a-f]{64}/Alight\\.zip$`, "u"));
    assert.equal(plan.releaseEndpoint, "https://owlandkestrel.com/api/admin/releases");
    assert.equal(plan.publicationOrder.includes("publish Release/Trust ledger"), true);
    assert.equal("trustPayload" in plan, false);
    assert.equal(stdout.includes("secret-one"), false);
    assert.equal(stdout.includes("secret-two"), false);
  } finally { await rm(f.directory, { recursive: true, force: true }); }
});

test("publication fails closed with no remaining direct R2 writer", async () => {
  const f = await fixture({ signed: true });
  try {
    await assert.rejects(run(f.directory, ["--publish"], { OK_RELEASE_PUBLIC_KEY_FILE: f.publicKeyPath }),
      /publication is frozen.*direct R2 writes are retired/iu);
    const source = await readFile(path.join(root, "scripts/publish-release.mjs"), "utf8");
    assert.equal(source.includes("wrangler"), false);
    assert.equal(source.includes("r2Put"), false);
    assert.equal(source.includes("r2 object put"), false);
  } finally { await rm(f.directory, { recursive: true, force: true }); }
});

test("local validation rejects dirty publication and appcast ambiguity before credentials", async () => {
  const dirty = await fixture({ dirty: true });
  try { await assert.rejects(run(dirty.directory, ["--publish"]), /dirty worktree/u); }
  finally { await rm(dirty.directory, { recursive: true, force: true }); }
  const mismatch = await fixture({ mutate: (p) => { p.updateFeed.sha256 = "0".repeat(64); return p; } });
  try { await assert.rejects(run(mismatch.directory), /Appcast bytes/u); }
  finally { await rm(mismatch.directory, { recursive: true, force: true }); }
  const kindless = await fixture({ mutate: (p) => { delete p.artifacts[0].kind; return p; } });
  try { await assert.rejects(run(kindless.directory), /artifact kind must be archive/u); }
  finally { await rm(kindless.directory, { recursive: true, force: true }); }
});

test("signed O+K provenance is verified and tampering is rejected", async () => {
  const f = await fixture({ signed: true });
  try {
    const result = await run(f.directory, [], { OK_RELEASE_PUBLIC_KEY_FILE: f.publicKeyPath });
    assert.equal(JSON.parse(result.stdout).manifestSignatureVerified, true);
    const file = path.join(f.directory, "alight-update.json");
    const document = JSON.parse(await readFile(file, "utf8"));
    document.signedPayload = `${document.signedPayload}A`;
    await writeFile(file, JSON.stringify(document));
    await assert.rejects(run(f.directory, [], { OK_RELEASE_PUBLIC_KEY_FILE: f.publicKeyPath }), /invalid|non-canonical|verification failed/u);
  } finally { await rm(f.directory, { recursive: true, force: true }); }
});

test("dry-run validates the Glideslope bridge when present and orders it after the Alight archive", async () => {
  const f = await fixture();
  try {
    const bridge = await bridgeFixture(f.directory);
    const { stdout } = await run(f.directory);
    const plan = JSON.parse(stdout);
    assert.equal(plan.bridge.artifactKey, `glideslope/releases/v0.5.2/${bridge.zipSha}/Glideslope.zip`);
    assert.equal(plan.bridge.sourceCommit, "9df75478514deb724fdf161c1f6862bb7761e599");
    assert.equal(plan.bridge.build, 12);
    assert.equal(plan.bridge.appcastKey, "glideslope/stable/appcast.xml");
    assert.equal(plan.bridge.hostBundleId, "com.owlandkestrel.glideslope");
    assert.equal(plan.bridge.manifestSignatureVerified, false);
    const order = plan.publicationOrder;
    assert.ok(order.indexOf("Nest stage/commit/read back bridge ZIP") > order.indexOf("Nest pointer CAS/read back appcast"));
    assert.ok(order.indexOf("Nest pointer CAS/read back Glideslope appcast") < order.indexOf("publish Release/Trust ledger"));
  } finally { await rm(f.directory, { recursive: true, force: true }); }
});

test("bridge validation rejects a mismatched host identity or archive", async () => {
  const wrongHost = await fixture();
  try {
    await bridgeFixture(wrongHost.directory, { mutate: (m) => { m.bundleId = "com.owlandkestrel.alight"; return m; } });
    await assert.rejects(run(wrongHost.directory), /Bridge manifest identity/u);
  } finally { await rm(wrongHost.directory, { recursive: true, force: true }); }
  const wrongBytes = await fixture();
  try {
    await bridgeFixture(wrongBytes.directory);
    await writeFile(path.join(wrongBytes.directory, "bridge", "Glideslope.zip"), Buffer.from("tampered"));
    await assert.rejects(run(wrongBytes.directory), /Bridge ZIP bytes/u);
  } finally { await rm(wrongBytes.directory, { recursive: true, force: true }); }
  const currentHead = await fixture();
  try {
    await bridgeFixture(currentHead.directory, { mutate: (m) => { m.source.commit = sourceCommit; return m; } });
    await assert.rejects(run(currentHead.directory), /not the pinned Glideslope bridge commit/u);
  } finally { await rm(currentHead.directory, { recursive: true, force: true }); }
  const relabelled = await fixture();
  try {
    await bridgeFixture(relabelled.directory, { mutate: (m) => { m.version = pkg.version; m.build = pkg.build; return m; } });
    await assert.rejects(run(relabelled.directory), /Bridge manifest identity does not match the admitted bridge/u);
  } finally { await rm(relabelled.directory, { recursive: true, force: true }); }
  const dirty = await fixture();
  try {
    await bridgeFixture(dirty.directory, { mutate: (m) => { m.source.dirty = true; return m; } });
    await assert.rejects(run(dirty.directory), /clean source tree/u);
  } finally { await rm(dirty.directory, { recursive: true, force: true }); }
  const notDescendant = await fixture({ alightCommit: preBridgeCommit });
  try {
    await bridgeFixture(notDescendant.directory);
    await assert.rejects(run(notDescendant.directory), /not an ancestor of the Alight release commit/u);
  } finally { await rm(notDescendant.directory, { recursive: true, force: true }); }
  const noBridge = await fixture();
  try {
    assert.equal(JSON.parse((await run(noBridge.directory)).stdout).bridge, null);
  } finally { await rm(noBridge.directory, { recursive: true, force: true }); }
});

test("signed bridge provenance verifies, and publication refuses an unsigned bridge", async () => {
  const signed = await fixture({ signed: true });
  try {
    await bridgeFixture(signed.directory, { signingKey: signed.privateKey });
    const { stdout } = await run(signed.directory, [], { OK_RELEASE_PUBLIC_KEY_FILE: signed.publicKeyPath });
    assert.equal(JSON.parse(stdout).bridge.manifestSignatureVerified, true);
    const other = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    await bridgeFixture(signed.directory, { signingKey: other.privateKey });
    await assert.rejects(run(signed.directory, [], { OK_RELEASE_PUBLIC_KEY_FILE: signed.publicKeyPath }), /signature/iu);
  } finally { await rm(signed.directory, { recursive: true, force: true }); }
  const unsignedBridge = await fixture({ signed: true });
  try {
    await bridgeFixture(unsignedBridge.directory);
    await assert.rejects(run(unsignedBridge.directory, ["--publish"], { OK_RELEASE_PUBLIC_KEY_FILE: unsignedBridge.publicKeyPath }),
      /unsigned bridge manifest/u);
  } finally { await rm(unsignedBridge.directory, { recursive: true, force: true }); }
});
