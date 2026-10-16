// Vane measures ref sizes with Buffer.byteLength; JavaScriptCore has no
// Buffer. Vane's own utf8Bytes counts exactly as Buffer does.
import { utf8Bytes } from "@owl-kestrel/vane";

export const Buffer = {
  byteLength(text, encoding) {
    if (typeof text !== "string" || (encoding !== undefined && encoding !== "utf8")) {
      throw new Error("alight-core: Buffer.byteLength accepts utf8 strings only");
    }
    return utf8Bytes(text);
  },
};
