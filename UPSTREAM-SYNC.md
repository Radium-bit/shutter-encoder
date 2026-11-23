# 跟进上游更新

本仓库在 [paulpacifico/shutter-encoder](https://github.com/paulpacifico/shutter-encoder) 之上维护一个去提示构建：保留上游功能与修复，去掉捐献弹窗、启动版本检查与设备信息采集。

分支约定：

| 分支 | 用途 |
| --- | --- |
| `master` | 上游镜像，只做快进，不提交本地改动 |
| `no-prompt` | 交付分支，承载本项目全部补丁 |

---

## 一、补丁清单

改动分为三类，升级时按类处理。

### 1. 纯新增文件（上游不会碰，无需处理）

| 文件 | 作用 |
| --- | --- |
| `build-noPrompt.ps1` | 编译 → fat jar → jpackage 镜像 → NSIS 打包 |
| `installer/ShutterEncoder.nsi` | 安装/卸载脚本，64 位注册表与快捷方式 |
| `audit-noPrompt.ps1` | 扫描是否重新出现弹窗、版本检查与遥测 |
| `.gitattributes` | 保护 `.ps1` / `.nsi` 的 UTF-8 BOM 与行尾 |
| `.gitignore` | 忽略 `Library`、`LUTs`、`build` 等运行期产物 |
| `Start-ShutterEncoder.ps1`、`run.bat` | 源码直跑的本地启动脚本 |

上游若新增同名文件，先确认用途再决定覆盖或合并。

### 2. 整文件删除（上游若重新上传该文件，需要再删一次）

| 文件 | 原因 |
| --- | --- |
| `src/shutterencoder/ui/others/Donate.java` | QR 捐献弹窗，内含 `MachineId` 采集主板序列号 |
| `src/resources/qrcode.png` | 仅捐献弹窗使用 |
| `src/shutterencoder/ui/main/ImageAdjustement.java` | 上游遗留拼写错误副本，引用不存在的字段，导致编译失败 |

`ImageAdjustement.java` 这一条要特别注意：它不是我们想去掉的功能，而是上游自带的编译错误。若上游某次修好了拼写，就应当恢复该文件并删除我们的删除操作。

上游若重新加回捐献弹窗，通常会同时修改 `Settings.java`。删掉 `Donate.java` 后，这些引用会导致编译失败，按下面五处排查（行号仅对应上游 `20.5`）：

| `Settings.java` 位置 | 内容 |
| --- | --- |
| 字段声明区 | `savedDayOfYear` |
| 组件名注册区 | `btnDisableUpdate.setName(...)` |
| 复选框布局链 | `btnDisableUpdate.setBounds(...)`、`btnDisableVideoPlayer` 的锚点 |
| `loadSettings` | `dayOfYear` 与 `textMailDonate` 的读取分支 |
| `saveSettings` | `dayOfYear` 写入与 `Element account` 中的 `textMailDonate` |
| 设置窗口底部 | `JButton donate` 及其 `MouseListener` |

编译报错信息会直接指向未定义符号（`Donate`、`showDonateWindow`、`savedDayOfYear`），逐个删除对应语句即可。

### 3. 定点修改（升级时最可能冲突，重点关注）

| 文件 | 改动 | 定位锚点 |
| --- | --- | --- |
| `utils/Utils.java` | 关闭流程直接 `System.exit(0)`，去掉 `showDonateWindow` 分支 | `Utils.exitApp(boolean hideFrame)` 方法末尾的 `//Check donate account` 段 |
| `ui/main/Main.java` | 删除 `showDonateWindow` 字段、删除 `Update.newVersion()` 调用、版本号改为组合生成 | `public static String actualVersion`、`Ytdlp.update();` 之后 |
| `ui/others/Update.java` | 删除 `newVersion()` 与 `runProcess()` | 保留 `HTTPDownload` 与进度窗口 |
| `ui/others/Settings.java` | 删除 `dayOfYear` 计数、`textMailDonate` 读写、捐献按钮、`btnDisableUpdate` 复选框 | `saveSettings` 的 `Element warning` 段、复选框布局链 |

**版本号是唯一的高冲突点。** 上游每次发版都会改 `actualVersion` 那一行，我们的版本号改造也落在这里。冲突时直接取上游的新版本号写进 `baseVersion`，其余保留：

```java
public static final String baseVersion = "20.6";   // ← 只改这一行
public static final String actualVersion = buildVersion(baseVersion, readBuildRevision());
```

---

## 二、升级步骤

```bash
# 1. 更新上游镜像（master 只做快进，不要在上面提交）
git checkout master
git fetch origin
git merge --ff-only origin/master

# 2. 把交付分支变基到新上游
git checkout no-prompt
git rebase master
```

变基时按上表的锚点解决冲突。绝大多数情况下只有 `Main.java` 的版本号一行需要处理。

```bash
# 3. 静态审计：确认没有被上游悄悄带回的弹窗与遥测
powershell -ExecutionPolicy Bypass -File ./audit-noPrompt.ps1 -Strict

# 4. 构建
powershell -ExecutionPolicy Bypass -File ./build-noPrompt.ps1
```

`audit-noPrompt.ps1 -Strict` 有非预期命中时返回非零码，可以直接当门禁用。

**务必先审计再构建。** 上游以 `Add files via upload` 整体上传为主，diff 噪声大，人工比对容易漏。审计脚本是唯一可靠的兜底。

```bash
# 5. 安装验证
#    安装 build/dist 下的 Setup.exe 后执行：
"C:\Program Files\Shutter Encoder\Shutter Encoder.exe" --version
#    应输出 v<baseVersion>-noPrompt-<当前提交号>
```

---

## 三、为什么用变基而不是合并

上游把多个文件整体重写、行尾风格不统一，长期合并会让历史里堆满分叉。变基把我们的补丁重放到新上游之上，保持「上游 + 一个补丁提交」的线性结构，历史可读、`git diff master..no-prompt` 始终等于真实补丁面。

代价是变基后提交号变化，**版本号里的 hash 也会变**，所以每次升级必须重新构建，不能沿用旧安装包。

如果本地已有基于旧提交的构建产物与用户安装，`--version` 会对不上，这是预期行为，重装即可。

---

## 四、需要定期复核的联网点

以下调用不是遥测，但会在无用户操作时联网。上游若新增，需要判断是否接受。

| 位置 | 行为 | 处置 |
| --- | --- | --- |
| `library/Ytdlp.java` | 每次启动执行 `yt-dlp -U` 自更新 | 保留。YouTube 频繁变更，不自更新会让网页下载功能失效 |
| `library/Deoldify.java` | 首次使用彩色化时从 HuggingFace 下载模型 | 保留。用户主动触发，属功能必需 |
| `library/Ytdlp.java` | 缺失时从 GitHub 下载 `yt-dlp` 本体 | 保留。同上 |
| `functions/Translate.java` | 字幕翻译调用 `translate.googleapis.com` | 保留。用户主动触发 |
| `Anonymizer.java`、`Whisper.java` | 跳转 PayPal 获取付费配套应用 | 保留。用户主动点击 |

审计脚本每次运行都会打印这份清单，新增条目应当先判断再决定是否放行。

如果要彻底禁止启动联网，把 `Main.java` 里的 `Ytdlp.update();` 一行注释掉即可，代价是网页视频下载功能会随 YouTube 改动逐渐失效。

---

## 五、已确认无遥测

本项目源码中不存在第三方统计 SDK（Google Analytics、Sentry、Mixpanel、Segment 等），唯一的设备信息采集是原 `Donate.java` 内的 `MachineId`（读取主板序列号后 SHA-256 上报），已随捐献弹窗一并移除，审计脚本对此设有常驻检查。
