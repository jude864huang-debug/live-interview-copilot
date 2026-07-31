# Live Interview Copilot

Live Interview Copilot is a macOS app for preparing and responding during remote product and business interviews. It separates interviewer system audio from the candidate microphone, transcribes the selected role in real time, and surfaces concise, grounded answer cues.

It never speaks for the candidate and does not store raw audio.

## What it does

- Builds a local role package from your resume, story bank, job description, company research, and domain material.
- Uses Tencent Cloud realtime ASR for the selected audio role, with local Qwen3-ASR as a slower fallback.
- Shows a fast opening, focused talking points, evidence anchors, and likely follow-up questions.
- Uses the OpenAI Responses API when configured. The locally signed-in Codex path is an experimental compatibility mode.
- Keeps transcripts and generated cues locally; it does not upload your compiled reference package.

## 腾讯 ASR 快速配置

Live Interview Copilot 默认使用腾讯云实时语音识别处理当前活动角色的音频。腾讯云 ASR 与 ChatGPT Pro、OpenAI API 分别计费，三者的额度不能互换。

### 1. 开通实时语音识别

1. 登录[腾讯云语音识别控制台](https://console.cloud.tencent.com/asr)。
2. 开通语音识别服务，并确认实时语音识别可用。
3. 检查账户余额、免费额度或资源包状态。服务未开通、资源包耗尽或账户欠费都会导致连接失败。

产品接口和计费规则可能调整，以[腾讯云语音识别官方文档](https://cloud.tencent.com/document/product/1093)及控制台当前显示为准。

### 2. 创建专用 API 密钥

1. 在[腾讯云访问管理（CAM）](https://console.cloud.tencent.com/cam)中创建一个仅供本应用使用的子用户。
2. 为该子用户授予使用实时语音识别所需的最小权限。若希望应用自动查询 APPID，还需要允许其读取当前账号 APPID；否则可以在应用中手动填写 APPID。
3. 在[API 密钥管理](https://console.cloud.tencent.com/cam/capi)中为该子用户创建 SecretID 和 SecretKey。

不要使用主账号永久密钥，也不要把 SecretID、SecretKey 写入源码、提交到 GitHub、粘贴到 Issue 或放进截图。

### 3. 在应用中填写

1. 打开 **Live Interview Copilot → Settings → Copilot → 面试 ASR**。
2. 音频模式选择“腾讯流式 ASR（手动分轮）”。
3. 填写 SecretID 和 SecretKey。
4. 点击 APPID 右侧的“自动获取”。如果子用户没有查询权限，也可以手动填写腾讯云账号的纯数字 APPID。
5. 点击“测试连接”，看到“腾讯云连接和鉴权成功”后再开始面试。

SecretID 和 SecretKey 只保存在 macOS Keychain 中。APPID 不属于密钥，但仍不建议与账号信息一起公开。

### 4. 识别模型与热词

当前默认使用腾讯云 `16k_zh` 标准实时识别模型。中英文混说时，公司名、产品名、人名和专业术语主要通过热词增强：

- 开启“根据面试材料自动生成热词”，应用会从本地面试材料提取候选词。
- 可以在“手动热词”中用逗号或换行补充重要术语，手动内容优先级最高。
- 腾讯模式只发送当前活动角色的音频和热词；精简面试知识包只发送给所选文字生成服务。

### 5. 常见错误

| 提示或错误码 | 处理方式 |
| --- | --- |
| APPID 自动获取失败 | 检查 CAM 查询权限，或直接手动填写纯数字 APPID。 |
| 鉴权失败 | 检查 AppID、SecretID、SecretKey 是否属于同一腾讯云账号，并删除首尾空格后重试。 |
| `4003` | 当前 AppID 尚未开通语音识别服务。 |
| `4004` | 实时语音识别资源包或可用额度已耗尽。 |
| `4005` | 腾讯云账户欠费。 |
| `4006` | 实时语音识别并发数超过账户限制。 |
| 连接失败或提前关闭 | 检查网络、防火墙和腾讯云服务状态，然后重新执行“测试连接”。 |

腾讯云暂时不可用时，应用可以尝试本地 Qwen3-ASR 慢速兜底；该兜底需要本机已安装对应程序和模型。

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
