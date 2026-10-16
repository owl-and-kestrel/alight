// Alight's JavaScriptCore entry point. Glue only: the logic lives in the
// upstream packages, and Swift talks to it through JSON strings so neither
// side depends on JSValue's object conversion rules.
import { fitTree } from "@owl-kestrel/vane";

export * as vane from "@owl-kestrel/vane";

/**
 * Fits `treeJSON` (a Vane LodNode) with `optionsJSON` (Vane FitOptions minus
 * functions). `accept`, when given, is the caller's own measure: it receives
 * each candidate's JSON value and text and is ANDed with the budget.
 */
export function fitJSON(treeJSON, optionsJSON, accept) {
  const options = JSON.parse(optionsJSON);
  if (typeof accept === "function") {
    options.accept = (candidate) => accept(JSON.stringify(candidate.value ?? null), candidate.text) === true;
  }
  const result = fitTree(JSON.parse(treeJSON), options);
  return JSON.stringify({
    text: result.text,
    value: result.value,
    omitted: result.omitted,
    metrics: result.metrics,
  });
}
