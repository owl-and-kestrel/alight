#!/usr/bin/env node

import { createHash, createPublicKey, verify } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseProductUpdateManifest, verifySignedReleaseManifest } from "@owl-kestrel/hatch-contracts";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
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

// Optional Glideslope bridge (script/package_bridge.sh): the same build wrapped
// as Glideslope.app for the historical feed. Validated here so the dry run
// covers both channels; publication order is Alight first, then the bridge.
const bridge = await validateBridge(path.join(releaseDir, "bridge"), { version, build, channel, zipSha256 });

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
  bridge,
  releaseEndpoint: new URL("/api/admin/releases", okOrigin).href,
  publicationOrder: ["verify signatures", "Nest stage/commit/read back immutable ZIP", "Nest pointer CAS/read back appcast",
    ...(bridge ? ["Nest stage/commit/read back bridge ZIP", "Nest pointer CAS/read back Glideslope appcast"] : []),
    "publish Release/Trust ledger", "announce Chirp"],
  chirpPayload, source: payload.source };
if (!publish) {
  process.stdout.write(`${JSON.stringify(plan, null, 2)}\n`);
  process.exit(0);
}

// Direct R2 mutation is retired. Keep the local validation/dry-run surface
// useful while publication is frozen, then fail closed before any credential
// lookup or remote write. Delete this gate only when the authenticated Nest
// release-origin client owns archive-first/pointer-last publication and exact
// public readback.
throw new Error("Alight publication is frozen until the authenticated Nest release-origin client is installed; direct R2 writes are retired.");

function validateManifest(value, expected) {
  parseProductUpdateManifest(value);
  if (value.schema !== "ok.product-update.v1" || value.appId !== "alight" || value.bundleId !== "com.owlandkestrel.alight"
    || value.version !== expected.version || value.build !== expected.build || value.channel !== expected.channel) throw new Error("Release manifest identity does not match package metadata.");
  if (!value.source || value.source.repository !== "https://github.com/owl-and-kestrel/alight.git" || !/^[0-9a-f]{40}$/u.test(value.source.commit || "")
    || typeof value.source.dirty !== "boolean" || value.source.buildConfiguration !== "release") throw new Error("Release manifest is missing exact source provenance.");
  if (!value.updateFeed || value.updateFeed.format !== "sparkle.appcast.v2" || !/^[0-9a-f]{64}$/u.test(value.updateFeed.sha256 || "")) throw new Error("Release manifest updateFeed is invalid.");
  if (!Array.isArray(value.artifacts) || value.artifacts.filter((x) => x.platform === "macos").length !== 1) throw new Error("Release manifest must contain exactly one macOS artifact.");
}

async function validateBridge(directory, expected) {
  const manifestFile = path.join(directory, "glideslope-bridge.json");
  if (!existsSync(manifestFile)) return null;
  const zipFile = path.join(directory, "Glideslope.zip");
  const appcastFile = path.join(directory, "appcast.xml");
  for (const required of [zipFile, appcastFile]) {
    if (!existsSync(required)) throw new Error(`Bridge artifact is missing: ${required}`);
  }
  const manifest = JSON.parse(await readFile(manifestFile, "utf8"));
  if (manifest.schema !== "ok.product-bridge.v1" || manifest.appId !== "alight" || manifest.legacyAppId !== "glideslope"
    || manifest.hostBundleId !== "com.owlandkestrel.glideslope" || manifest.bundleId !== "com.owlandkestrel.alight"
    || manifest.version !== expected.version || manifest.build !== expected.build || manifest.channel !== expected.channel) {
    throw new Error("Bridge manifest identity does not match package metadata.");
  }
  const zip = await readFile(zipFile);
  const appcast = await readFile(appcastFile);
  const bridgeZipSha256 = sha256Bytes(zip);
  const bridgeAppcastSha256 = sha256Bytes(appcast);
  const artifact = (manifest.artifacts || []).find((item) => item.platform === "macos");
  if (!artifact || artifact.archiveAppName !== "Glideslope.app") throw new Error("Bridge manifest must describe one macOS Glideslope.app artifact.");
  if (artifact.sha256 !== bridgeZipSha256 || artifact.sizeBytes !== zip.length) throw new Error("Bridge ZIP bytes do not match the bridge manifest.");
  if (bridgeZipSha256 === expected.zipSha256) throw new Error("Bridge ZIP must be the Glideslope.app wrapping, not the Alight archive.");
  if (manifest.legacyFeed?.format !== "sparkle.appcast.v2" || manifest.legacyFeed.sha256 !== bridgeAppcastSha256) throw new Error("Bridge appcast bytes do not match the bridge manifest.");
  const item = parseAppcast(appcast.toString("utf8"));
  if (item.version !== expected.version || item.build !== String(expected.build)) throw new Error("Bridge appcast version/build does not match package metadata.");
  if (item.url !== artifact.url || item.length !== String(zip.length)) throw new Error("Bridge appcast enclosure does not match the bridge ZIP.");
  if (!item.signature) throw new Error("Bridge appcast enclosure is missing an Ed25519 signature.");
  const bridgeURL = new URL(artifact.url);
  if (bridgeURL.origin !== updateOrigin.origin || bridgeURL.pathname !== `/glideslope/releases/v${expected.version}/${bridgeZipSha256}/Glideslope.zip`) {
    throw new Error("Bridge artifact URL is not the content-addressed canonical Glideslope release-origin URL.");
  }
  const legacyFeedURL = new URL(manifest.legacyFeed.url);
  if (legacyFeedURL.origin !== updateOrigin.origin || legacyFeedURL.pathname !== `/glideslope/${expected.channel}/appcast.xml`) throw new Error("Bridge feed URL is not the canonical Glideslope feed.");
  return {
    artifactKey: bridgeURL.pathname.slice(1), appcastKey: legacyFeedURL.pathname.slice(1),
    artifactSha256: bridgeZipSha256, appcastSha256: bridgeAppcastSha256, hostBundleId: manifest.hostBundleId
  };
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
