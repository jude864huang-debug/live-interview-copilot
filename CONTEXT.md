# Live Interview Copilot

This context covers a candidate's live interview, from captured turns to the
guidance and reference answers available during that interview.

## Interview flow

**Interview Round**:
One interviewer question and the candidate response context it creates, ending
when the next interviewer question begins. Only its latest Question Revision
can be displayed or archived.
_Avoid_: request, generation, prompt

**Question Revision**:
The current authoritative wording of an Interview Round's interviewer question
after ASR finalisation, correction, merging, or explicit regeneration.
_Avoid_: draft, partial, version

**Session Fallback Owner**:
The fallback model that takes ownership of reference answers for the remainder
of one interview session after the primary model fails.
_Avoid_: per-request fallback, temporary fallback

**Verified Entry**:
The first reference-answer content validated for an Interview Round and safe
for the candidate to use before the complete answer arrives.
_Avoid_: partial response, stream chunk

**Answer Freeze**:
The state after the candidate begins answering in which new reference content
does not automatically replace the visible guidance, while the current round
may finish in the background.
_Avoid_: cancellation, pause

## Knowledge grounding

**Knowledge Package**:
The complete, categorised source set for one target role. It remains local and
is the source from which Knowledge Briefs are derived.
_Avoid_: role package, reference package, knowledge base

**Knowledge Brief**:
A bounded, Question Revision-specific representation derived from a Knowledge
Package and sent to the selected answer provider.
_Avoid_: compact brief, uploaded package, prompt context

**Candidate Fact**:
A claim that the candidate personally did, achieved, measured, or experienced.
It requires support from a resume or story-bank source.
_Avoid_: personal claim, candidate history

**Professional Judgment**:
A methodology, decision process, trade-off, or hypothetical approach that does
not assert past candidate experience.
_Avoid_: generic filler, unsupported experience

**Explicit Assumption**:
A condition stated as hypothetical because the available sources do not
establish it as fact.
_Avoid_: invented fact, guess
