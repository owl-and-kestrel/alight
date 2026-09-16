#!/usr/bin/env node

import { createHash, createPublicKey, verify } from "node:crypto";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { parseProductUpdateManifest, verifySignedReleaseManifest } from "@owl-kestrel/hatch-contracts";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const execFileAsync = promisify(execFile);
const flags = new Set(process.argv.slice(2));
const publish = flags.has("--publish");
const allowDirty = flags.has("--allow-dirty");
const allowUnsigned = flags.has("--allow-unsigned");
const releaseDir = process.env.ALIGHT_RELEASE_DIR || path.join(root, "dist/release");
const zipPath = path.join(releaseDir, "Alight.zip");
const appcastPath = path.join(releaseDir, "appcast.xml");
const manifestPath = path.join(releaseDir, "alight-update.json");
const channel = process.env.ALIGHT_RELEASE_CHANNEL || "stable";
const updateOrigin = validatedOrigin(process.env.ALIGHT_UPDATE_ORIGIN || "https://updates.owlandkestrel.com");
const okOrigin = validatedOrigin(process.env.ALIGHT_OK_BASE_URL || "https://owlandkestrel.com");
const chirpChannel = process.env.ALIGHT_CHIRP_CHANNEL || "alight-updates";

if (flags.has("--help")) {
  process.stdout.write("Usage: node scripts/publish-release.mjs [--publish] [--allow-dirty] [--allow-unsigned]\n");
  process.exit(0);
}
if (!/^[a-z0-9][a-z0-9-]{0,31}$/u.test(channel)) throw new Error("Invalid release channel.");
for (const required of [zipPath, appcastPath, manifestPath]) {
  if (!existsSync(required)) throw new Error(`Release artifact is missing: ${required}`);
}

const packageJSON = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
const manifestDocument = JSON.parse(await readFile(manifestPath, "utf8"));
const version = String(packageJSON.version || "");
const build = Number(packageJSON.build);
if (!/^\d+(?:\.\d+){1,3}$/u.test(version) || !Number.isSafeInteger(build) || build <= 0) {
  throw new Error("package.json must contain a valid version and positive integer build.");
}
const decoded = await decodeAndVerifyManifest(manifestDocument, { version, build, channel });
const payload = decoded.payload;
validateManifest(payload, { version, build, channel });
if (publish && payload.source.dirty && !allowDirty) throw new Error("Refusing to publish an artifact built from a dirty worktree.");
if (publish && !decoded.signatureVerified && !allowUnsigned) throw new Error("Refusing to publish an unsigned release manifest.");

const zip = await readFile(zipPath);
const appcast = await readFile(appcastPath);
const zipSha256 = sha256Bytes(zip);
const appcastSha256 = sha256Bytes(appcast);
const artifact = payload.artifacts.find((item) => item.platform === "macos");
if (artifact.sha256 !== zipSha256 || artifact.sizeBytes !== zip.length) throw new Error("ZIP bytes do not match the release manifest.");
if (payload.updateFeed.sha256 !== appcastSha256) throw new Error("Appcast bytes do not match the release manifest.");

const item = parseAppcast(appcast.toString("utf8"));
if (item.version !== version || item.build !== String(build)) throw new Error("Appcast version/build does not match package metadata.");
if (item.url !== artifact.url || item.length !== String(zip.length)) throw new Error("Appcast enclosure does not match the ZIP manifest.");
if (!item.signature) throw new Error("Appcast enclosure is missing an Ed25519 signature.");
const artifactURL = new URL(artifact.url);
const expectedArtifactPath = `/alight/releases/v${version}/${zipSha256}/Alight.zip`;
if (artifactURL.origin !== updateOrigin.origin || artifactURL.pathname !== expectedArtifactPath) {
  throw new Error("Artifact URL is not the content-addressed canonical release-origin URL.");
}
const expectedFeedPath = `/alight/${channel}/appcast.xml`;
const feedURL = new URL(payload.updateFeed.url);
if (feedURL.origin !== updateOrigin.origin || feedURL.pathname !== expectedFeedPath) throw new Error("Update feed URL is not canonical.");

const artifactKey = artifactURL.pathname.slice(1);
const appcastKey = feedURL.pathname.slice(1);
const dedupeKey = `alight:${channel}:${version}:${build}:${zipSha256}`;
const chirpPayload = {
  channel: chirpChannel, kind: "event", subtype: "product.release_available",
  body: `Alight ${version} (${build}) is available. ${payload.downloadPageUrl}`,
  payload: { eventType: "product.release_available", dedupeKey, severity: "info", product: "alight", channel,
    version, build, releaseUrl: payload.downloadPageUrl, artifactSha256: zipSha256, sourceCommit: payload.source.commit }
};

const plan = { mode: publish ? "publish" : "dry-run", version, build, channel,
  publicationAuthority: "nest-owned-release-origin", publicationStatus: "frozen-pending-authenticated-nest-client",
  artifactKey, appcastKey,
  artifactSha256: zipSha256, appcastSha256, manifestSignatureVerified: decoded.signatureVerified,
  releaseEndpoint: new URL("/api/admin/releases", okOrigin).href,
  publicationOrder: ["verify signatures", "Nest stage/commit/read back immutable ZIP", "Nest pointer CAS/read back appcast",
    "publish Release/Trust ledger", "announce Chirp"],
  chirpPayload, source: payload.source };
if (!publish) {
  process.stdout.write(`${JSON.stringify(plan, null, 2)}\n`);
  process.exit(0);
}

// Publication is delegated to the authenticated Nest host client. The
// publisher never learns credentials and never writes the origin directly.
const nestCliPath = String(process.env.ALIGHT_NEST_CLI_PATH || "").trim();
const planFile = String(process.env.ALIGHT_RELEASE_ORIGIN_PLAN_FILE || "").trim();
const planId = String(process.env.ALIGHT_RELEASE_ORIGIN_PLAN_ID || "").trim();
const expectedVersion = String(process.env.ALIGHT_RELEASE_ORIGIN_EXPECTED_VERSION || "").trim();
const bridgeArtifactPath = String(process.env.ALIGHT_BRIDGE_ARTIFACT_PATH || "").trim();
const bridgeAppcastPath = String(process.env.ALIGHT_BRIDGE_APPCAST_PATH || "").trim();
const bridgeManifestPath = String(process.env.ALIGHT_BRIDGE_MANIFEST_PATH || "").trim();
if (!nestCliPath || !path.isAbsolute(nestCliPath) || !planFile || !planId || !expectedVersion
  || !bridgeArtifactPath || !bridgeAppcastPath || !bridgeManifestPath) {
  throw new Error("Alight publication requires ALIGHT_NEST_CLI_PATH, ALIGHT_RELEASE_ORIGIN_PLAN_FILE, ALIGHT_RELEASE_ORIGIN_PLAN_ID, ALIGHT_RELEASE_ORIGIN_EXPECTED_VERSION, and the three ALIGHT_BRIDGE_*_PATH values.");
}
const delegated = await execFileAsync(process.execPath, [nestCliPath, "deploy", "plan", "execute", "--file", planFile,
  "--id", planId, "--expected-version", expectedVersion, "--artifact-path", zipPath, "--appcast-path", appcastPath,
  "--manifest-path", manifestPath, "--bridge-artifact-path", bridgeArtifactPath, "--bridge-appcast-path", bridgeAppcastPath,
  "--bridge-manifest-path", bridgeManifestPath, "--yes", "--json"], { cwd: root, env: process.env, encoding: "utf8", maxBuffer: 2 * 1024 * 1024 });
const delegatedResult = JSON.parse(delegated.stdout);
if (delegatedResult?.type !== "ok.nest.release-origin-publication-execution.v1" || delegatedResult.status !== "completed") {
  throw new Error("Nest release-origin client returned an invalid completion receipt.");
}
process.stdout.write(`${JSON.stringify(delegatedResult, null, 2)}\n`);

function validateManifest(value, expected) {
  parseProductUpdateManifest(value);
  if (value.schema !== "ok.product-update.v1" || value.appId !== "alight" || value.bundleId !== "com.owlandkestrel.alight"
    || value.version !== expected.version || value.build !== expected.build || value.channel !== expected.channel) throw new Error("Release manifest identity does not match package metadata.");
  if (!value.source || value.source.repository !== "https://github.com/owl-and-kestrel/alight.git" || !/^[0-9a-f]{40}$/u.test(value.source.commit || "")
    || typeof value.source.dirty !== "boolean" || value.source.buildConfiguration !== "release") throw new Error("Release manifest is missing exact source provenance.");
  if (!value.updateFeed || value.updateFeed.format !== "sparkle.appcast.v2" || !/^[0-9a-f]{64}$/u.test(value.updateFeed.sha256 || "")) throw new Error("Release manifest updateFeed is invalid.");
  if (!Array.isArray(value.artifacts) || value.artifacts.filter((x) => x.platform === "macos").length !== 1) throw new Error("Release manifest must contain exactly one macOS artifact.");
}

function parseAppcast(xml) {
  const one = (pattern, label) => {
    const values = [...xml.matchAll(pattern)].map((match) => match[1]);
    if (values.length !== 1) throw new Error(`Appcast must contain exactly one ${label}.`);
    return decodeXML(values[0]);
  };
  const enclosureMatches = [...xml.matchAll(/<enclosure\b([^>]*?)\/?\s*>/gu)];
  if (enclosureMatches.length !== 1) throw new Error("Appcast must contain exactly one enclosure.");
  const attrs = enclosureMatches[0][1];
  const attr = (name, label = name) => {
    const values = [...attrs.matchAll(new RegExp(`(?:^|\\s)(?:sparkle:)?${name}="([^"]*)"`, "gu"))].map((m) => decodeXML(m[1]));
    if (values.length !== 1) throw new Error(`Appcast enclosure must contain exactly one ${label}.`);
    return values[0];
  };
  return {
    version: one(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/gu, "short version"),
    build: one(/<sparkle:version>([^<]+)<\/sparkle:version>/gu, "build"),
    url: attr("url"), length: attr("length"), signature: attr("edSignature", "Ed25519 signature")
  };
}

function decodeXML(value) { return value.replaceAll("&amp;", "&").replaceAll("&quot;", '"').replaceAll("&lt;", "<").replaceAll("&gt;", ">"); }
function sha256Bytes(bytes) { return createHash("sha256").update(bytes).digest("hex"); }
function validatedOrigin(value) {
  const url = new URL(value); const loopback = ["127.0.0.1", "::1", "localhost"].includes(url.hostname);
  if ((url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) || url.username || url.password) throw new Error("Origins must use HTTPS or loopback HTTP without credentials.");
  return url;
}
async function decodeAndVerifyManifest(document, expected) {
  if (document.schema !== "ok.signed-manifest.v1") {
    parseProductUpdateManifest(document);
    return { payload: document, signatureVerified: false };
  }
  if (document.publisher?.id !== "owl-kestrel" || document.publisher?.domain !== "owlandkestrel.com"
    || document.publisher?.keyId !== (process.env.OK_RELEASE_KEY_ID || "ok-release-p256-v1") || document.signature?.alg !== "ECDSA_P256_SHA256_DER") throw new Error("Signed release manifest has unexpected publisher metadata.");
  const publicKeyPEM = await readReleasePublicKey();
  const publicKey = createPublicKey(publicKeyPEM);
  const spkiDer = publicKey.export({ type: "spki", format: "der" });
  const spkiSha256 = createHash("sha256").update(spkiDer).digest("hex");
  const keyId = document.publisher.keyId;
  const trustedPublishers = [{
    id: "owl-kestrel",
    domain: "owlandkestrel.com",
    keyId,
    algorithm: "ECDSA_P256_SHA256_DER",
    publicKeyPem: publicKeyPEM
  }];
  const policy = {
    productId: "alight",
    appId: "alight",
    packageId: "com.owlandkestrel.alight",
    channel: expected.channel,
    publisher: {
      id: "owl-kestrel",
      domain: "owlandkestrel.com",
      allowedKeys: [{ keyId, publicKeySpkiSha256: spkiSha256 }]
    },
    // Preserve the established Sparkle key identifier while the product and
    // bundle identities migrate. The Ed25519 key bytes are unchanged.
    executableTrust: { authority: "product-native", verifier: "sparkle-ed25519", keyId: "sparkle-glideslope-1" },
    installer: { adapterId: "alight.sparkle.macos.v1", kind: "native-updater" },
    allowedSourceRepositories: ["https://github.com/owl-and-kestrel/alight.git"],
    sourceBuildConfigurations: ["release"],
    allowedArtifactOrigins: [updateOrigin.origin],
    allowedArtifactPathPrefixes: ["/alight/"],
    allowedFeedOrigins: [updateOrigin.origin, okOrigin.origin],
    allowedFeedFormats: ["sparkle.appcast.v2"],
    allowedPlatforms: ["macos"],
    requireCleanSource: !allowDirty,
    requireExpiry: false,
    maxArtifactBytes: 50 * 1024 * 1024,
    allowLoopbackHttpForDevelopment: true
  };
  const verified = verifySignedReleaseManifest(document, {
    trustedPublishers,
    policy,
    now: new Date()
  });
  return { payload: verified.payload, signatureVerified: true, verifiedManifest: verified };
}
async function readReleasePublicKey() {
  const direct = String(process.env.OK_RELEASE_PUBLIC_KEY_PEM || "").trim(); if (direct) return direct;
  const file = process.env.OK_RELEASE_PUBLIC_KEY_FILE || path.join(root, "config/ok-release-p256-v1.pub.pem");
  return (await readFile(file, "utf8")).trim();
}
function decodeBase64URL(value, label) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/u.test(value)) throw new Error(`Signed release manifest ${label} is invalid.`);
  const bytes = Buffer.from(value, "base64url"); if (bytes.toString("base64url") !== value) throw new Error(`Signed release manifest ${label} is non-canonical.`); return bytes;
}
