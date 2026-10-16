// Vane hashes canonical JSON for content refs with node:crypto. JavaScriptCore
// has no crypto module, so Alight's host supplies SHA-256 (CryptoKit).
export function createHash(algorithm) {
  if (algorithm !== "sha256") throw new Error(`alight-core: unsupported hash ${algorithm}`);
  let text = "";
  return {
    update(chunk, encoding) {
      if (typeof chunk !== "string" || (encoding !== undefined && encoding !== "utf8")) {
        throw new Error("alight-core: createHash().update accepts utf8 strings only");
      }
      text += chunk;
      return this;
    },
    digest(format) {
      if (format !== "hex") throw new Error(`alight-core: unsupported digest ${format}`);
      return globalThis.__alightHost.sha256Hex(text);
    },
  };
}
