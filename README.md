# Live Interview Copilot

Live Interview Copilot is a macOS app for preparing and responding during remote
product and business interviews. It separates interviewer system audio from the
candidate microphone, transcribes the selected role in real time, and surfaces
concise, grounded answer cues.

It never speaks for the candidate and does not store raw audio.

## What it does

- Builds a local role package from your resume, story bank, job description,
  company research, and domain material.
- Uses Tencent Cloud realtime ASR for the selected audio role, with local
  Qwen3-ASR as a slower fallback.
- Shows a fast opening, focused talking points, evidence anchors, and likely
  follow-up questions.
- Uses an LLM API first when configured, with the local Codex CLI path as a
  fallback or explicit alternative.
- Keeps transcripts and generated cues locally; it does not upload your
  compiled reference package.

## 用户快速开始

第一次使用时，按这个顺序配置：

1. 配置腾讯云实时 ASR，点击“测试连接”。
2. 配置文字生成：优先选择 API；只有本机 `codex login` 已成功时才选择 Codex CLI。
3. 在“音频检查”中确认麦克风、系统音频和权限正常。
4. 选择本地面试材料并点击“重新编译”，然后开始面试。

面试过程中默认使用手动分轮，不依赖 VAD 自动判断说话结束。快捷键和完整流程见
[默认快捷键](#默认快捷键)和[手动分轮流程](#手动分轮流程)。

## 腾讯 ASR 快速配置

Live Interview Copilot 默认使用腾讯云实时语音识别处理当前活动角色的音频。
腾讯云 ASR、LLM API 和 ChatGPT Pro 分别计费，额度不能互换。

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
3. 面试官音频来源通常选择“系统音频”；如果面试在手机上进行，可以选择“本机麦克风”，让手机开免提并靠近电脑麦克风。
4. 填写 SecretID 和 SecretKey。
5. 点击 APPID 右侧的“自动获取”。如果子用户没有查询权限，也可以手动填写腾讯云账号的纯数字 APPID。
6. 点击“测试连接”，看到“腾讯云连接和鉴权成功”后再开始面试。

系统音频模式需要麦克风和屏幕录制权限；“本机麦克风”听题模式只需要麦克风权限。设置页的“音频检查”可以先做 3 秒测试，再开始真实面试。

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

## 文字生成（LLM）配置

文字生成和腾讯云 ASR 是两套独立服务。没有 ChatGPT 账号或 ChatGPT 订阅时，
优先使用 API；ChatGPT 订阅额度也不能直接当作 OpenAI API 额度。

### 推荐：API 优先

API 路径只需要对应服务商的 API key，不要求 ChatGPT 账号：

1. 打开 **Settings → Copilot → 文字生成**。
2. “生成通路”选择 **API 优先**。
3. 在“API 协议”中选择服务商支持的协议：
   - **OpenAI**：选择 `Responses API`，Base URL 填 `https://api.openai.com`。
   - **DeepSeek**：选择 `Chat Completions`，Base URL 填
     `https://api.deepseek.com`，默认模型可使用 `deepseek-chat`。
   - 其他 OpenAI-compatible 服务：填写它的 API 根地址和对应协议。应用会自动补上 `/v1/responses` 或 `/v1/chat/completions`，不要重复填写完整路径。
4. 填写 API Key，点击“验证并加载模型”。验证成功后，在“主回答模型”中选择该账号实际可用的模型。
5. 可选：设置“备用回答模型”。主模型在产生第一句之前失败时，应用会尝试备用模型。

API key 只保存在 macOS Keychain。API 服务商的账号、计费和限额由服务商单独管理；
不要把 key 写进源码、提交到 GitHub 或粘贴到 Issue。

在 **API 优先**模式下，应用会先调用 API；如果没有可用 API key，或请求在产生首句前失败，才会尝试 Codex CLI。两边都没有配置时，面试可以收音和转写，但不会生成文字回答。

### 备用：Codex CLI

Codex CLI 是本机登录的另一条文字生成通路。选择它之前，先在终端确认登录状态：

```bash
codex login
codex login status
```

如果没有 ChatGPT 账号但有 OpenAI API key，当前 Codex CLI 也支持从标准输入完成 API key 登录；不要把 key 写进命令历史：

```bash
printf '%s' "$OPENAI_API_KEY" | codex login --with-api-key
codex login status
```

然后在 **Settings → Copilot → 文字生成**中选择 **仅 Codex CLI**，填写或选择
Codex 模型。应用读取本机 Codex 登录状态，不使用上面 API 配置框中的 key。
登录状态无效、模型不可用或 Codex worker 未启动时，运行详情会显示失败原因。

如果从源码运行，Codex worker 的依赖需要先安装：

```bash
npm --prefix worker ci
```

## 默认快捷键

快捷键在面试进行时生效；设置页的“全局快捷键”可以重新录制主分轮快捷键。

| 快捷键 | 功能 | 使用时机 |
| --- | --- | --- |
| `⌥Z`（Option+Z） | 手动换轮 | 面试官说完按一次，结束问题并生成提示；你回答完再按一次，保存回答并切回面试官 |
| `⌥A`（Option+A） | 打开/关闭镜头卡 | 面试过程中随时显示或隐藏大字提示卡 |
| `←` / `→` | 镜头卡翻页 | 镜头卡打开时切换内容页 |
| `⌃⌥M` | 合并上一段 | ASR 把同一轮切成多段时合并 |
| `⌃⌥S` | 停止生成 | 停止当前正在生成的文字回答 |

### 手动分轮流程

1. 点击 **Start**，确认状态显示正在听面试官。
2. 面试官说完，按 `⌥Z`。当前问题会定稿，应用开始生成快速思路和回答。
3. 你开始回答；回答结束后再按 `⌥Z`。本轮回答会保存，应用切回面试官收音。
4. 需要大字提示时按 `⌥A`；镜头卡打开后可用左右方向键翻页。

如果快捷键没有反应，先确认面试正在运行、应用没有停在快捷键录制状态，
并在 Settings → Copilot → 全局快捷键中查看当前主分轮键。旧版本保存过自定义
快捷键的用户不会被覆盖；点击“恢复默认”后才会使用新的默认 `⌥Z`。

## Development

```bash
npm --prefix worker ci

cd LiveInterviewCopilot
swift run LiveInterviewCopilot
```

只有使用 Codex CLI 路径时才需要额外执行 `codex login`；API 路径不需要 ChatGPT 登录。

For a local app bundle:

```bash
SKIP_SIGN=1 SKIP_INSTALL=1 ./scripts/build_swift_app.sh
```

The first full release requires a Developer ID Application certificate, Apple
notarization credentials, and a new Sparkle EdDSA key pair configured as
repository secrets. The prior product's update feed is deliberately disabled.

## Use responsibly

Use the app only where interview rules and recording laws permit it, and obtain
any required consent. Live Interview Copilot does not include screen-share
hiding or monitoring-evasion features.

## Source history and license

This project began from OpenOats and has since been substantially reworked as
an interview copilot. The repository keeps that commit history for traceability.
OpenOats is MIT licensed; its required copyright notice and license remain in
[LICENSE](LICENSE).
