# 桌宠伙伴

一个 macOS 桌面应用，统一管理 GPT 白龙和 DeepSeek 大肥鱼。每种最多一只，可以同时陪伴。原有大肥鱼项目和发行历史保留在这个仓库。

![大肥鱼吃大白饭](docs/rice.gif)

## 使用

- 在主窗口召唤、找到或收回伙伴。收回会结束对应进程，删除该实例临时数据，不累积编号。
- 两种角色分别调整大小，范围 80 至 224，也可跟随 Codex 的宠物尺寸。
- 关闭窗口后伙伴继续运行，点击 Dock 图标重开管理窗口。退出应用会收回伙伴，可选择下次打开时恢复。
- 运行 Codex 任务时工作，空闲时散步。两种受管桌宠不增加 Mac 顶部菜单栏图标。
- 大肥鱼保留 12 项完整动作、白色两列三行分页表情框、黑色粗体字幕及活泼调皮的中文配音。
- 六种双宠互动：击掌、贴贴、双人舞、招手跑来、抛接星星、追逐玩耍。空闲时按距离选择，也可在「一起玩」中点选。
- 每种互动有双方分别发起的版本，共十二套三轮对白、三十六句双声线录音。接住星星、碰掌或追到伙伴后自然回应，语音轮流播放。
- 白龙采用青春御姐声线，二十三句常用、表情和每日问候录音已包含。八项表情以两列三行分成两页，保留完整动作和语音。
- 工作、拖动、点表情、隐藏或收回时双方让位，停止当前对话，不补播余下轮次。
- 白龙画面需导入你有权使用的原有白龙应用或素材。

## 下载和安装

从 [Releases](https://github.com/Yolanda101/deepseek-whale-pet/releases/tag/companion-v1.3) 下载 `DesktopPetStudio-companion-v1.3-macos-arm64.zip`。适用于 Apple Silicon Mac，macOS 13 及以上。应用采用临时签名，尚未经过 Apple 公证。

解压后打开 `dist/桌宠伙伴.app`，或把它移到你的 Applications 文件夹。运行成品不需要 Python、AI 模型或联网合成语音。

需要注册登录启动时，在解压目录运行以下命令，需要 Python 3。安装器会安装到当前用户的 Applications，备份并迁移本项目原有登录项，保留旧独立应用。它不会删除旧应用。

```sh
python3 companion/install.py --dry-run
python3 companion/install.py
```

如需首次启用 Codex 大肥鱼表情助手，安装时加 `--native-helper`。已有统一版更新使用 `--update-only`，保留登录项设置。

```sh
python3 companion/install.py --native-helper
python3 companion/install.py --update-only
```

## 白龙素材导入

公开包不附带白龙美术素材。原作者没有向所有访问者开放美术素材再分发许可，增强版发布者获得的授权也没有扩展到本项目。[原作素材说明](https://github.com/jingh12312-rgb/bailong-desktop-pet/blob/main/ASSETS.md) · [增强版授权说明](https://github.com/Wunsch2048/codex-bailong-desktop-pet/blob/main/NOTICE.md)

点击白龙卡片的「导入白龙素材」，选择你有权使用的原有「桌宠伙伴.app」「GPT龙娘桌面伴侣.app」，或包含 `Frames` 的素材文件夹。导入器只保存八组共 51 张动画图片，不复制原应用的程序、账号、偏好或运行记录。随后即可召唤白龙。

帧规格及来源见 [白龙说明](assets/dragon/NOTICE.md)。导入只发生在使用者本机，不上传素材。

若升级前的应用内含白龙画面，请先退出旧应用，用解压后的公开版导入旧应用素材，再执行安装或更新。这样素材会保存在本机数据目录，替换旧应用后仍可使用。

## Codex 大肥鱼外观

把 `codex-pet/deepseek-q-whale` 复制到 `~/.codex/pets/`，自定义了 `CODEX_HOME` 时放到其 `pets` 子目录。在 Codex 宠物设置中选择「DeepSeek 大肥鱼 · 手办版」。

公开表情助手只识别通用本地外观 `custom:deepseek-q-whale`。启用助手后，鼠标悬停显示每页两列三行的表情框，左右翻页，点击播放完整动作。此入口依赖 Codex 当前的本地宠物格式和窗口布局。

## 从源码构建

需要 Apple Silicon Mac、macOS 13 以上、Xcode Command Line Tools 和 Python 3。

```sh
python3 -B companion/build.py
python3 -B companion/install.py --dry-run
```

产物为 `dist/桌宠伙伴.app`。构建只使用仓库中的公开源码、动画和录音，不读取开发者的本机工程、配置或配音环境。

```sh
# 使用你有权使用的素材，在本机静音、隔离数据目录运行完整验收
DESKTOP_PET_DRAGON_ARTWORK_DIR=/path/to/dragon-resources python3 -B companion/verify.py dist/桌宠伙伴.app
DESKTOP_PET_DRAGON_ARTWORK_DIR=/path/to/dragon-resources python3 -B companion/verify_dialogue.py dist/桌宠伙伴.app
DESKTOP_PET_DRAGON_ARTWORK_DIR=/path/to/dragon-resources python3 -B companion/verify_social.py dist/桌宠伙伴.app
DESKTOP_PET_DRAGON_ARTWORK_DIR=/path/to/dragon-resources python3 -B companion/dragon/verify_expressions.py dist/桌宠伙伴.app
python3 -B app/verify.py dist/桌宠伙伴.app/Contents/Resources/Engines/DeepSeek大肥鱼.app
python3 -B scripts/package_companion.py
```

完整验收需要真实 macOS 图形会话，覆盖每种最多一只、同时两种、尺寸边界、重复召唤、收回数据清理、正常退出、崩溃恢复和目录保护。白龙素材需具备 `Frames/{dance,idle,jumping,running,running-left,running-right,waiting,waving}`，分别为 8、6、5、6、8、8、6、4 帧，命名 `00.png` 起，单帧 288×312 或 192×208。

原大肥鱼独立版仍可用 `python3 -B app/build.py` 构建，参见 [旧版说明](docs/legacy-whale.md)。

## 对白与声音

白龙沿用清亮、温柔自信的青春御姐声，大肥鱼使用活泼调皮声。两种参考声均由 Qwen3-TTS VoiceDesign 根据原创成年角色描述生成，再用 Base 模型合成台词。成品录音离线播放，不包含配音模型。来源见 [白龙声音](assets/dragon/Voice/语音来源.md)、[大肥鱼声音](assets/voice/production/配音来源.md) 和 [双宠对白](assets/dialogue/语音来源.md)。

每次互动等待双方接单后才开始。对话按音频实际时长安排，原动作时长独立计算，收尾时继续自然回应。静音时保留字幕。

## 本地数据和隐私

运行偏好保存在 `~/Library/Application Support/DesktopPetStudio/`。明确收回会删除对应实例目录；角色大小设置保留。白龙导入素材放在其中的 `DragonArtwork`，单独保存。原生表情助手沿用本机 `DeepSeekWhalePet/CodexExpressions` 状态目录。

应用读取本机 Codex 的任务活动和宠物尺寸，用于工作动画和窗口同步。声音离线播放，应用不配置上传用户数据的服务。公开仓和发布包排除个人目录、登录配置、私有宠物标识、运行日志、凭据、配音模型和 Python 环境。提交使用项目通用署名。

## 目录和许可

| 目录 | 内容 |
| --- | --- |
| `companion/` | 统一窗口、安装、构建、生命周期验收和白龙引擎 |
| `app/` | 大肥鱼引擎、Codex 表情助手和共享模块 |
| `assets/figurine/`、`assets/motion/` | 大肥鱼完整动作和表情 |
| `assets/voice/` | 大肥鱼活泼调皮配音和制作记录 |
| `assets/dragon/` | 白龙二十三句配音和八项表情引擎所用字幕，画面由使用者自行导入 |
| `assets/dialogue/` | 十二套三轮互动对白，三十六句录音及统一时长、哈希清单 |
| `codex-pet/` | Codex 本地大肥鱼外观 |
| `scripts/` | 可重建的发布打包工具 |

原创代码采用 MIT。大肥鱼角色、动作、图标和本项目合成录音按 CC BY-NC-SA 4.0 分享。白龙美术不包含在该授权范围内。完整第三方署名和许可见 [NOTICE](NOTICE.md)。
