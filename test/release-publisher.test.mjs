import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);
const root = path.resolve(new URL("..", import.meta.url).pathname);
const pkg = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));

async function fixture({ dirty = false, signed = false, mutate = (value) => value } = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "glideslope-publisher-"));
  const zip = Buffer.from("signed update fixture", "utf8");
  const zipSha = createHash("sha256").update(zip).digest("hex");
  const artifactURL = `https://updates.owlandkestrel.com/glideslope/releases/v${pkg.version}/${zipSha}/Glideslope.zip`;
  const appcast = Buffer.from(`<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:shortVersionString>${pkg.version}</sparkle:shortVersionString><sparkle:version>${pkg.build}</sparkle:version><enclosure url="${artifactURL}" length="${zip.length}" sparkle:edSignature="fixture-signature" /></item></channel></rss>`, "utf8");
  const appcastSha = createHash("sha256").update(appcast).digest("hex");
  let payload = {
    schema: "ok.product-update.v1", appId: "glideslope", bundleId: "com.owlandkestrel.glideslope",
    version: pkg.version, build: pkg.build, channel: "stable", publishedAt: new Date().toISOString(), downloadPageUrl: "https://owlandkestrel.com/apps/glideslope",
    updateFeed: { format: "sparkle.appcast.v2", url: "https://updates.owlandkestrel.com/glideslope/stable/appcast.xml", sha256: appcastSha },
    source: { repository: "https://github.com/owl-and-kestrel/glideslope.git", commit: "4bc7afebc8ccaaa02c26d404b7ec1f724951e41d", dirty, buildConfiguration: "release" },
    artifacts: [{ platform: "macos", url: artifactURL, sha256: zipSha, sizeBytes: zip.length }]
  };
  payload = mutate(structuredClone(payload));
  let document = payload;
  let publicKeyPath = "";
  if (signed) {
    const bytes = Buffer.from(`${JSON.stringify(payload, null, 2)}\n`);
    const keys = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    document = { schema: "ok.signed-manifest.v1", publisher: { id: "owl-kestrel", domain: "owlandkestrel.com", keyId: "ok-release-p256-v1" },
      signedPayload: bytes.toString("base64url"), signature: { alg: "ECDSA_P256_SHA256_DER", value: sign("sha256", bytes, keys.privateKey).toString("base64url") } };
    publicKeyPath = path.join(directory, "key.pem");
    await writeFile(publicKeyPath, keys.publicKey.export({ type: "spki", format: "pem" }));
  }
  await writeFile(path.join(directory, "Glideslope.zip"), zip);
  await writeFile(path.join(directory, "appcast.xml"), appcast);
  await writeFile(path.join(directory, "glideslope-update.json"), `${JSON.stringify(document)}\n`);
  return { directory, publicKeyPath };
}

async function run(directory, extra = [], env = {}) {
  return execFileAsync(process.execPath, ["scripts/publish-release.mjs", ...extra], { cwd: root,
    env: { ...process.env, GLIDESLOPE_RELEASE_DIR: directory, ...env } });
}

test("dry-run validates the content-addressed ZIP and appcast without leaking credentials", async () => {
  const f = await fixture();
  try {
    const { stdout } = await run(f.directory, [], { GLIDESLOPE_OK_API_KEY: "secret-one", GLIDESLOPE_CHIRP_API_KEY: "secret-two" });
    const plan = JSON.parse(stdout);
    assert.equal(plan.mode, "dry-run");
    assert.equal(plan.publicationAuthority, "nest-owned-release-origin");
    assert.equal(plan.publicationStatus, "frozen-pending-authenticated-nest-client");
    assert.equal(plan.build, pkg.build);
    assert.match(plan.artifactKey, new RegExp(`/v${pkg.version}/[0-9a-f]{64}/Glideslope\\.zip$`, "u"));
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
});

test("signed O+K provenance is verified and tampering is rejected", async () => {
  const f = await fixture({ signed: true });
  try {
    const result = await run(f.directory, [], { OK_RELEASE_PUBLIC_KEY_FILE: f.publicKeyPath });
    assert.equal(JSON.parse(result.stdout).manifestSignatureVerified, true);
    const file = path.join(f.directory, "glideslope-update.json");
    const document = JSON.parse(await readFile(file, "utf8"));
    document.signedPayload = `${document.signedPayload}A`;
    await writeFile(file, JSON.stringify(document));
    await assert.rejects(run(f.directory, [], { OK_RELEASE_PUBLIC_KEY_FILE: f.publicKeyPath }), /invalid|non-canonical|verification failed/u);
  } finally { await rm(f.directory, { recursive: true, force: true }); }
});
