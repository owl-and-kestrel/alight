// Alight's JavaScriptCore entry point. Glue only: the logic lives in the
// upstream packages, and Swift talks to it through JSON strings so neither
// side depends on JSValue's object conversion rules.
import { quotaObservationProblems, quotaWindowPace } from "@owl-kestrel/fieldbook/quota";
import { fitTree } from "@owl-kestrel/vane";

export * as vane from "@owl-kestrel/vane";
export * as fieldbookQuota from "@owl-kestrel/fieldbook/quota";

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

/** Fieldbook's structural check of an ok.fieldbook.quota-observation.v1 value. */
export function quotaObservationProblemsJSON(observationJSON) {
  return JSON.stringify(quotaObservationProblems(JSON.parse(observationJSON)));
}

/**
 * Fieldbook's (Astra-ported) pace for each window in `windowsJSON` (Astra's
 * snake_case window shape) under `policyJSON` at `nowMs`. An empty object is
 * a window Fieldbook cannot pace.
 */
export function quotaWindowPaceJSON(windowsJSON, policyJSON, nowMs) {
  const policy = JSON.parse(policyJSON);
  return JSON.stringify(JSON.parse(windowsJSON).map((window) => quotaWindowPace(window, { policy, now: nowMs })));
}
