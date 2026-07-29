# Live Interview Copilot

Live Interview Copilot is a macOS app for preparing and responding during remote product and business interviews. It separates interviewer system audio from the candidate microphone, transcribes the selected role in real time, and surfaces concise, grounded answer cues.

It never speaks for the candidate and does not store raw audio.

## What it does

- Builds a local role package from your resume, story bank, job description, company research, and domain material.
- Uses Tencent Cloud realtime ASR for the selected audio role, with local Qwen3-ASR as a slower fallback.
- Shows a fast opening, focused talking points, evidence anchors, and likely follow-up questions.
- Uses the OpenAI Responses API when configured. The locally signed-in Codex path is an experimental compatibility mode.
- Keeps transcripts and generated cues locally; it does not upload your compiled reference package.

## Development

```bash
npm --prefix worker install
codex login

cd LiveInterviewCopilot
swift run LiveInterviewCopilot
```

For a local app bundle:

```bash
SKIP_SIGN=1 SKIP_INSTALL=1 ./scripts/build_swift_app.sh
```

The first full release requires a Developer ID Application certificate, Apple notarization credentials, and a new Sparkle EdDSA key pair configured as repository secrets. The prior product's update feed is deliberately disabled.

## Use responsibly

Use the app only where interview rules and recording laws permit it, and obtain any required consent. Live Interview Copilot does not include screen-share hiding or monitoring-evasion features.

## Source history and license

This project began from OpenOats and has since been substantially reworked as an interview copilot. The repository keeps that commit history for traceability. OpenOats is MIT licensed; its required copyright notice and license remain in [LICENSE](LICENSE).
