import assert from "node:assert/strict";
import test from "node:test";
import {
  canSwitchTransportAfterAppServerFailure,
  configWithModelCatalogPath,
  cueOutputSchema,
  followUpAnswerOutputSchema,
  followUpsOutputSchema,
  normalizeModelCatalog,
  normalizeGenerateMessage,
  promptWithOutputBudget,
  progressiveAnswerOutputSchema,
  referenceAnswerOutputSchema,
  schemaForKind
} from "./codex-worker.mjs";

test("older model catalogs get the required reasoning-summary capability field", () => {
  const original = {
    models: [
      { slug: "native", supports_reasoning_summaries: true },
      { slug: "external" }
    ],
    version: 1
  };
  const normalized = normalizeModelCatalog(original);
  assert.equal(normalized.changed, true);
  assert.equal(normalized.catalog.version, 1);
  assert.equal(normalized.catalog.models[0].supports_reasoning_summaries, true);
  assert.equal(normalized.catalog.models[1].supports_reasoning_summaries, false);
});

test("current model catalogs are left untouched", () => {
  const catalog = { models: [{ slug: "native", supports_reasoning_summaries: true }] };
  const normalized = normalizeModelCatalog(catalog);
  assert.equal(normalized.changed, false);
  assert.equal(normalized.catalog, catalog);
});

test("compatibility Codex home replaces the inherited catalog before CLI startup", () => {
  const config = 'model = "gpt-5.6-terra"\nmodel_catalog_json = "/old/catalog.json"\n';
  const normalized = configWithModelCatalogPath(config, "/tmp/compatible-catalog.json");
  assert.ok(normalized.includes('model_catalog_json = "/tmp/compatible-catalog.json"'));
  assert.doesNotMatch(normalized, /old\/catalog/);
});

test("transport fallback never concatenates a second JSON document after a delta", () => {
  assert.equal(canSwitchTransportAfterAppServerFailure(false), true);
  assert.equal(canSwitchTransportAfterAppServerFailure(true), false);
});

test("cue schema keeps the live card bounded", () => {
  assert.equal(schemaForKind("cue"), cueOutputSchema);
  assert.equal(cueOutputSchema.properties.talkingPoints.minItems, 3);
  assert.equal(cueOutputSchema.properties.talkingPoints.maxItems, 5);
  assert.equal(cueOutputSchema.properties.evidenceAnchors.maxItems, 2);
  assert.equal(cueOutputSchema.properties.missingFacts.maxItems, 3);
  assert.equal(cueOutputSchema.properties.likelyFollowUps.maxItems, 3);
});

test("reference-answer requests use their own schema", () => {
  assert.equal(schemaForKind("referenceAnswer"), referenceAnswerOutputSchema);
  assert.equal(referenceAnswerOutputSchema.properties.segments.minItems, 3);
  assert.equal(referenceAnswerOutputSchema.properties.segments.maxItems, 3);
  assert.equal(referenceAnswerOutputSchema.properties.missingFacts.maxItems, 3);
  assert.equal(cueOutputSchema.properties.questionSummary.type, "string");
  assert.equal(referenceAnswerOutputSchema.properties.questionSummary, undefined);
});

test("progressive answer schema keeps semantic stages aligned", () => {
  assert.equal(schemaForKind("answer"), progressiveAnswerOutputSchema);
  assert.deepEqual(progressiveAnswerOutputSchema.required, ["entry", "spine", "segments", "closing", "metadata"]);
  assert.deepEqual(Object.keys(progressiveAnswerOutputSchema.properties), ["entry", "spine", "segments", "closing", "metadata"]);
  assert.equal(progressiveAnswerOutputSchema.properties.spine.minItems, 2);
  assert.equal(progressiveAnswerOutputSchema.properties.spine.maxItems, 4);
  assert.deepEqual(progressiveAnswerOutputSchema.properties.spine.items.required, ["id", "label", "role", "claimType", "sourceIDs"]);
  assert.equal(progressiveAnswerOutputSchema.properties.spine.items.properties.cue, undefined);
  assert.equal(progressiveAnswerOutputSchema.properties.segments.minItems, 2);
  assert.equal(progressiveAnswerOutputSchema.properties.segments.maxItems, 4);
  assert.equal(progressiveAnswerOutputSchema.properties.closing.anyOf[0].type, "null");
});

test("third-stage requests use bounded follow-up schemas", () => {
  assert.equal(schemaForKind("followUps"), followUpsOutputSchema);
  assert.equal(followUpsOutputSchema.properties.items.minItems, 3);
  assert.equal(followUpsOutputSchema.properties.items.maxItems, 3);
  assert.equal(schemaForKind("followUpAnswer"), followUpAnswerOutputSchema);
  assert.deepEqual(followUpAnswerOutputSchema.required, [
    "directOpening", "talkingPoints", "sampleAnswer", "sourceIDs", "estimatedSpeakingSeconds"
  ]);
  assert.equal(followUpAnswerOutputSchema.properties.talkingPoints.minItems, 2);
  assert.equal(followUpAnswerOutputSchema.properties.talkingPoints.maxItems, 3);
  assert.equal(followUpAnswerOutputSchema.properties.estimatedSpeakingSeconds.minimum, 20);
  assert.equal(followUpAnswerOutputSchema.properties.estimatedSpeakingSeconds.maximum, 40);
});

test("Swift snake-case worker fields are normalized", () => {
  const request = normalizeGenerateMessage({
    id: "request-id",
    model: "gpt-5.3-codex-spark",
    prompt: "question",
    kind: "referenceAnswer",
    max_output_tokens: 900,
    fast_service_tier: true,
    reasoning_effort: "medium"
  });
  assert.deepEqual(request, {
    id: "request-id",
    model: "gpt-5.3-codex-spark",
    prompt: "question",
    kind: "referenceAnswer",
    maxOutputTokens: 900,
    fastServiceTier: true,
    reasoningEffort: "medium"
  });
});

test("Codex reasoning efforts include high and extra high", () => {
  assert.equal(normalizeGenerateMessage({ reasoning_effort: "high" }).reasoningEffort, "high");
  assert.equal(normalizeGenerateMessage({ reasoning_effort: "xhigh" }).reasoningEffort, "xhigh");
  assert.equal(normalizeGenerateMessage({ reasoning_effort: "unsupported" }).reasoningEffort, "low");
});

test("invalid budgets get a safe per-kind default and valid budgets are bounded", () => {
  assert.equal(normalizeGenerateMessage({ kind: "cue" }).maxOutputTokens, 450);
  assert.equal(normalizeGenerateMessage({ kind: "answer" }).maxOutputTokens, 1_800);
  assert.equal(normalizeGenerateMessage({ kind: "referenceAnswer" }).maxOutputTokens, 700);
  assert.equal(normalizeGenerateMessage({ kind: "followUps" }).maxOutputTokens, 300);
  assert.equal(normalizeGenerateMessage({ kind: "followUpAnswer" }).maxOutputTokens, 550);
  assert.equal(normalizeGenerateMessage({ max_output_tokens: 1 }).maxOutputTokens, 64);
  assert.equal(normalizeGenerateMessage({ max_output_tokens: 10_000 }).maxOutputTokens, 2_600);
});

test("the requested output budget reaches the model prompt", () => {
  const prompt = promptWithOutputBudget("base", 450, "cue");
  assert.match(prompt, /max_tokens="450"/);
  assert.match(prompt, /3-5 short talking points/);
});

test("progressive budget describes one layered answer", () => {
  const prompt = promptWithOutputBudget("base", 1_800, "answer");
  assert.match(prompt, /complete entry first/);
  assert.match(prompt, /all 2-4 short spine labels with no detail/);
  assert.match(prompt, /segments in spine ID order/);
});

test("follow-up prompts match their strict schemas", () => {
  const questionsPrompt = promptWithOutputBudget("base", 300, "followUps");
  assert.match(questionsPrompt, /exactly 3 concise likely interviewer follow-up questions/);

  const answerPrompt = promptWithOutputBudget("base", 550, "followUpAnswer");
  assert.match(answerPrompt, /one direct opening/);
  assert.match(answerPrompt, /2-3 speakable points/);
  assert.match(answerPrompt, /20-40 second sample answer/);
});
