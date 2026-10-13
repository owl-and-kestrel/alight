#!/usr/bin/env node

// Alight release provenance: builds the `ok.product-update.v1` payloads for the
// Alight archive and the Glideslope bridge, and wraps a payload in the O+K
// `ok.signed-manifest.v1` P-256 envelope.
//
// The field names and the envelope match what Nest's release-origin publisher
// verifies (Nest scripts/nest-sparkle-publication.mjs,
// verifyOkReleaseManifestForProduct): exactly one macOS artifact with
// `kind: "archive"`, `source.dirty`/`buildConfiguration`, and a
// `sparkle.appcast.v2` updateFeed bound to the appcast digest. Every payload
// also passes @owl-kestrel/hatch-contracts' strict parser, which is why no
// bridge-only fields appear in the bridge payload.
//
// The envelope bytes match the estate signer
// (utilities/ok-release-tools/scripts/sign-manifest.mjs): the signed payload is
// `JSON.stringify(payload, null, 2) + "\n"`. That signer reads the key only from
// OK_RELEASE_PRIVATE_KEY_PEM; this one also accepts OK_RELEASE_PRIVATE_KEY_FILE
// so the key never has to enter an environment variable. Nest's own key-file
// signer (`nest fledge release sign`) is the estate-wide successor once Alight
// has a Hatch release config; retire this module's signer then.
//
// CLI:
//   release-manifest.mjs payload alight|bridge   payload JSON to stdout (inputs from ALIGHT_* env)
//   release-manifest.mjs sign <payload.json> <manifest.json>
//     Signs when OK_RELEASE_PRIVATE_KEY_FILE (preferred) or OK_RELEASE_PRIVATE_KEY_PEM
//     is set; otherwise writes the payload bytes unchanged as an unsigned preview.

import { createPrivateKey, createPublicKey, sign, verify } from "node:crypto";
import { constants as fsConstants, realpathSync } from "node:fs";
import { lstat, open, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ALIGHT_SOURCE_REPOSITORY = "https://github.com/owl-and-kestrel/alight.git";
export const DEFAULT_PUBLISHER = Object.freeze({ id: "owl-kestrel", name: "Owl & Kestrel", domain: "owlandkestrel.com", keyId: "ok-release-p256-v1" });
const MAX_PRIVATE_KEY_BYTES = 64 * 1024;

/** Alight's own release: identity com.owlandkestrel.alight on the Alight feed. */
export function buildAlightPayload(input) {
  return productUpdatePayload({ ...input, appId: "alight", bundleId: "com.owlandkestrel.alight" });
}

/**
 * The Glideslope bridge: the same Alight build wrapped as Glideslope.app for
 * the historical feed. Its update identity is the Glideslope host that Sparkle
 * updates (appId glideslope, bundle com.owlandkestrel.glideslope) and its feed
 * is the legacy appcast; its source is the Alight commit it was built from.
 */
export function buildBridgePayload(input) {
  return productUpdatePayload({ ...input, appId: "glideslope", bundleId: "com.owlandkestrel.glideslope" });
}

function productUpdatePayload(input) {
  const required = ["version", "build", "channel", "publishedAt", "downloadPageUrl", "feedUrl", "feedSha256",
    "sourceCommit", "sourceDirty", "buildConfiguration", "architectures", "artifactUrl", "artifactSha256", "artifactSizeBytes"];
  for (const field of required) {
    if (input[field] === undefined || input[field] === null || input[field] === "") throw new Error(`Release payload input ${field} is required.`);
  }
  const build = Number(input.build);
  const sizeBytes = Number(input.artifactSizeBytes);
  if (!Number.isSafeInteger(build) || build < 1) throw new Error("Release payload build must be a positive integer.");
  if (!Number.isSafeInteger(sizeBytes) || sizeBytes < 1) throw new Error("Release payload artifact size must be a positive integer.");
  if (typeof input.sourceDirty !== "boolean") throw new Error("Release payload sourceDirty must be boolean.");
  const architectures = Array.isArray(input.architectures) ? input.architectures : String(input.architectures).split(/\s+/u).filter(Boolean);
  return {
    schema: "ok.product-update.v1",
    appId: input.appId,
    bundleId: input.bundleId,
    version: String(input.version),
    build,
    channel: String(input.channel),
    ...(input.minimumSystemVersion ? { minimumSystemVersion: String(input.minimumSystemVersion) } : {}),
    publishedAt: String(input.publishedAt),
    ...(input.releaseNotes ? { releaseNotes: String(input.releaseNotes) } : {}),
    downloadPageUrl: String(input.downloadPageUrl),
    updateFeed: {
      format: "sparkle.appcast.v2",
      url: String(input.feedUrl),
      sha256: String(input.feedSha256),
      ...(input.sparklePublicKey ? { publicKey: String(input.sparklePublicKey) } : {}),
      automaticByDefault: true
    },
    source: {
      repository: ALIGHT_SOURCE_REPOSITORY,
      commit: String(input.sourceCommit),
      dirty: input.sourceDirty,
      buildConfiguration: String(input.buildConfiguration)
    },
    artifacts: [{
      platform: "macos",
      architectures,
      kind: "archive",
      url: String(input.artifactUrl),
      sha256: String(input.artifactSha256),
      sizeBytes
    }]
  };
}

/** Maps the packager's ALIGHT_* environment (non-secret metadata) to payload input. */
export function payloadInputFromEnv(env) {
  return {
    version: env.ALIGHT_VERSION,
    build: env.ALIGHT_BUILD_NUMBER,
    channel: env.ALIGHT_RELEASE_CHANNEL,
    minimumSystemVersion: env.ALIGHT_MIN_SYSTEM_VERSION,
    publishedAt: env.ALIGHT_PUBLISHED_AT,
    releaseNotes: env.ALIGHT_RELEASE_NOTES,
    downloadPageUrl: env.ALIGHT_DOWNLOAD_PAGE_URL,
    feedUrl: env.ALIGHT_APPCAST_URL,
    feedSha256: env.ALIGHT_APPCAST_SHA256,
    sparklePublicKey: env.ALIGHT_SPARKLE_PUBLIC_KEY,
    sourceCommit: env.ALIGHT_SOURCE_COMMIT,
    sourceDirty: env.ALIGHT_SOURCE_DIRTY === "true" ? true : env.ALIGHT_SOURCE_DIRTY === "false" ? false : undefined,
    buildConfiguration: env.ALIGHT_SOURCE_BUILD_CONFIGURATION,
    architectures: env.ALIGHT_ARCHITECTURES,
    artifactUrl: env.ALIGHT_ARTIFACT_URL,
    artifactSha256: env.ALIGHT_ARTIFACT_SHA256,
    artifactSizeBytes: env.ALIGHT_ARTIFACT_SIZE_BYTES
  };
}

/**
 * Reads an owner-only P-256 private key file. Refuses a symbolic link, a
 * non-regular file, another owner, or any group/other permission bit (so 0600
 * and 0400 pass, 0644 does not). The file is opened with O_NOFOLLOW and must be
 * the same inode that was inspected.
 */
export async function readReleasePrivateKeyFile(filePath) {
  if (typeof filePath !== "string" || !path.isAbsolute(filePath)) throw new Error("OK_RELEASE_PRIVATE_KEY_FILE must be an absolute path.");
  const before = await lstat(filePath);
  if (before.isSymbolicLink()) throw new Error("OK_RELEASE_PRIVATE_KEY_FILE must not be a symbolic link.");
  assertOwnerOnlyRegularFile(before);
  const handle = await open(filePath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  let bytes;
  try {
    const opened = await handle.stat();
    if (opened.dev !== before.dev || opened.ino !== before.ino) throw new Error("OK_RELEASE_PRIVATE_KEY_FILE changed while it was being opened.");
    assertOwnerOnlyRegularFile(opened);
    bytes = await handle.readFile();
  } finally {
    await handle.close();
  }
  try {
    return p256PrivateKey(bytes);
  } finally {
    bytes.fill(0);
  }
}

function assertOwnerOnlyRegularFile(stats) {
  if (!stats.isFile()) throw new Error("OK_RELEASE_PRIVATE_KEY_FILE must be a regular file.");
  if ((stats.mode & 0o077) !== 0) throw new Error("OK_RELEASE_PRIVATE_KEY_FILE must be mode 0600 (no group or other access).");
  if (typeof process.getuid === "function" && stats.uid !== process.getuid()) throw new Error("OK_RELEASE_PRIVATE_KEY_FILE must be owned by the signing user.");
  if (stats.size < 1 || stats.size > MAX_PRIVATE_KEY_BYTES) throw new Error("OK_RELEASE_PRIVATE_KEY_FILE has an implausible size.");
}

function p256PrivateKey(material) {
  let key;
  try { key = createPrivateKey(material); } catch (error) { throw new Error("O+K release private key is not a valid private key.", { cause: error }); }
  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") throw new Error("O+K release private key must be ECDSA P-256.");
  return key;
}

/**
 * Returns the configured signing key, or null for an unsigned preview.
 * OK_RELEASE_PRIVATE_KEY_PEM is the legacy inline form kept for existing
 * operators; delete it once release hosts use OK_RELEASE_PRIVATE_KEY_FILE.
 */
export async function resolveReleaseSigningKey(env) {
  const file = env.OK_RELEASE_PRIVATE_KEY_FILE || "";
  const pem = env.OK_RELEASE_PRIVATE_KEY_PEM || "";
  if (file && pem) throw new Error("Set only one of OK_RELEASE_PRIVATE_KEY_FILE and OK_RELEASE_PRIVATE_KEY_PEM.");
  if (file) return readReleasePrivateKeyFile(file);
  if (pem) return p256PrivateKey(pem);
  return null;
}

export function publisherFromEnv(env) {
  return {
    id: env.OK_RELEASE_PUBLISHER_ID || DEFAULT_PUBLISHER.id,
    name: env.OK_RELEASE_PUBLISHER_NAME || DEFAULT_PUBLISHER.name,
    domain: env.OK_RELEASE_PUBLISHER_DOMAIN || DEFAULT_PUBLISHER.domain,
    keyId: env.OK_RELEASE_KEY_ID || DEFAULT_PUBLISHER.keyId
  };
}

/** Wraps a payload in the O+K ok.signed-manifest.v1 envelope and self-verifies it. */
export function signManifestPayload(payload, privateKey, publisher = DEFAULT_PUBLISHER) {
  const payloadBytes = Buffer.from(`${JSON.stringify(payload, null, 2)}\n`, "utf8");
  const signature = sign("sha256", payloadBytes, { key: privateKey, dsaEncoding: "der" });
  if (!verify("sha256", payloadBytes, createPublicKey(privateKey), signature)) throw new Error("Generated O+K release signature did not verify.");
  return {
    schema: "ok.signed-manifest.v1",
    publisher: { ...publisher },
    signedPayload: payloadBytes.toString("base64url"),
    signature: { alg: "ECDSA_P256_SHA256_DER", value: signature.toString("base64url") }
  };
}

/** Signs payloadPath into manifestPath, or copies it unchanged when no key is configured. */
export async function signManifestFile(payloadPath, manifestPath, env = process.env) {
  const payloadText = await readFile(payloadPath, "utf8");
  const payload = JSON.parse(payloadText);
  const key = await resolveReleaseSigningKey(env);
  if (!key) {
    await writeFile(manifestPath, payloadText);
    return { signed: false };
  }
  const envelope = signManifestPayload(payload, key, publisherFromEnv(env));
  await writeFile(manifestPath, `${JSON.stringify(envelope, null, 2)}\n`);
  return { signed: true, keyId: envelope.publisher.keyId };
}

async function main(argv) {
  const [command, ...rest] = argv;
  if (command === "payload" && rest.length === 1 && (rest[0] === "alight" || rest[0] === "bridge")) {
    const input = payloadInputFromEnv(process.env);
    const payload = rest[0] === "alight" ? buildAlightPayload(input) : buildBridgePayload(input);
    process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
    return;
  }
  if (command === "sign" && rest.length === 2) {
    const result = await signManifestFile(rest[0], rest[1]);
    process.stderr.write(result.signed
      ? `Signed ${rest[1]} with ${result.keyId}.\n`
      : `No O+K release key configured; ${rest[1]} is an unsigned preview.\n`);
    return;
  }
  process.stderr.write("usage: release-manifest.mjs payload alight|bridge\n       release-manifest.mjs sign <payload.json> <manifest.json>\n");
  process.exitCode = 2;
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
