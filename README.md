# DeepSeek 大肥鱼桌宠

住在 macOS 桌面上的 Q 版蓝发鲸鱼娘。透明逐帧动画保留手办风格的脸、卷发和胖尾巴，支持中文配音，也能给 Codex 的本地大肥鱼外观加上可翻页的表情菜单。

![大肥鱼吃大白饭](docs/rice.gif)

## 互动

- Codex 运行任务时用笔记本工作，空闲时在屏幕内散步。
- 鼠标悬停显示白色表情面板，每页两列三行，左右翻页，点击播放完整动作。
- 1.9 为 12 个表情和任务完成提醒重新配音。大肥鱼用同一套原创普通话声线打招呼、撒娇、生气和道歉。字幕逐句对应，动作先结束时，声音继续读完。
- 半透明白底对话框，纯黑粗体台词。
- 可拖动、静音、隐藏，选择闲时散步或原地休息。
- 尺寸可跟随 Codex 的宠物设置，也可在菜单中独立调整。
- 提供任务完成语音提醒，默认关闭，可在菜单栏开启。
- 附带 Q 版手办和原版动画两种外观。12 项表情适用于 Q 版手办。

打招呼、撒娇、跳舞、气鼓鼓、累晕了、讨饭吃、甩尾巴、喂鱼、想出门玩、伤心掉眼泪、吃大白饭、很愧疚。

## 下载

在本仓库主页的 Releases 页面下载 `DeepSeekWhalePet-v1.9-macos-arm64.zip`。当前发布包适用于 Apple Silicon Mac，系统要求为 macOS 13 或更新版本。应用采用本机临时签名，尚未经过 Apple 公证。

解压后可直接打开 `dist/DeepSeek大肥鱼桌宠.app` 使用独立桌宠。要安装到当前用户的 Applications 目录并启用 Codex 表情助手，在解压目录运行以下命令，需要 Python 3。

```sh
python3 app/install.py
```

安装器会注册当前用户的登录项 `com.local.deepseek.whalepet.expressions`，使表情助手在 Codex 开启时工作。安装器支持首次安装和升级，升级沿用本机偏好。可先运行 `python3 app/install.py --dry-run` 查看安装位置及校验签名。

## Codex 本地外观

把 `codex-pet/deepseek-q-whale` 文件夹复制到 `~/.codex/pets/`。如果自定义了 `CODEX_HOME`，则放到其 `pets` 子目录。打开 Codex 的宠物设置，选择「DeepSeek 大肥鱼 · 手办版」。

表情助手识别这个外观的本地编号 `custom:deepseek-q-whale`。安装助手后，在 Codex 中将鼠标停留在大肥鱼身上即可翻页点播。这套外观与助手依赖 Codex 桌面版当前的本地宠物格式和窗口布局，后续客户端更新可能需要适配。

## 从源码构建

安装 Xcode Command Line Tools 和 Python 3。在仓库根目录执行以下命令，使用当前 Mac 的架构编译。

```sh
python3 app/build.py
```

产物为 `dist/DeepSeek大肥鱼桌宠.app`。运行和构建使用仓库自带的动画与声音素材。重新制作声音需要的工具另见 [配音来源](assets/voice/production/配音来源.md)。

```sh
python3 app/verify.py dist/DeepSeek大肥鱼桌宠.app
python3 app/tests/verify_native.py dist/DeepSeek大肥鱼桌宠.app /tmp/whale-native-qa.json
```

这些验证需要 macOS 图形会话，使用独立临时偏好和零音量播放器，检查工作状态、12 个表情、台词匹配、完整播放、翻页及中断行为。

安装 Pillow 后，`python3 codex-pet/build.py` 可核对原生图集，添加 `--write` 可从透明帧重建。

## 工程内容

| 目录 | 内容 |
| --- | --- |
| `app/` | Swift AppKit 桌宠、原生表情助手、构建和安装脚本 |
| `app/shared/` | Codex 活动识别、原生定位和尺寸读取 |
| `assets/figurine/` | 手办版透明动作帧、帧时长和表情图标 |
| `assets/motion/` | 原版动画帧及来源 |
| `assets/voice/` | 13 段普通话录音、台词清单及制作脚本 |
| `codex-pet/` | Codex 本地外观和图集构建工具 |
| `docs/` | 角色与动作预览 |

执行 `python3 scripts/package_release.py` 可将已构建的应用、安装脚本、本地外观和许可打包到 `releases/`，同时生成 SHA-256 校验文件。

## 本地数据

桌宠从本机 Codex 状态中读取任务活动和宠物设置，用于工作动画、窗口定位及尺寸同步。用户偏好和运行状态写入本机 `~/Library/Application Support/DeepSeekWhalePet/`。应用内配音直接播放随包提供的 WAV。

## 署名与许可

本项目是社区同人桌宠。鲸鱼娘「溟月」原作者为上善无形，DeepSeek 女仆版由 ZipZipPipe 设计。原版动画来自 PC2005-cloud 的 dsh-pet。手办动作及图标由本项目使用 Image 生成并整理，本项目在 Qwen 官方演示中用 VoiceDesign 设计普通话声线，再用同一段参考声音录制全部台词。问候由官方演示中的 Base 模型合成，其余 12 句在 Apple 芯片上用同款 Base 模型合成。成品录音随桌宠离线播放。[素材来源及修改说明](assets/素材署名.md)

本项目原创代码采用 MIT。角色、动画、图标、角色预览及本项目的合成录音采用 CC BY-NC-SA 4.0。分享时需保留署名、标明改动并沿用相同许可。具体范围见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE.md)。
