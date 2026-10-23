# Todo macOS 未签名 Release 与干净环境验收

本项目采用 MarkText 式 GitHub 发版：仓库提供源码，GitHub Release 提供可下载 ZIP 与 SHA-256 校验文件。应用采用 ad-hoc 签名，没有 Apple Developer ID 签名，也没有经过 Apple 公证；不要求维护者购买 Apple Developer Program 会员。OAuth 令牌和用户应用凭证继续保存在 macOS Keychain。

> 这里的“未签名 Release”指没有 Apple Developer ID 的发布者签名。为了形成可验证的 app bundle，打包脚本会对应用做 ad-hoc 签名；它不能让 Gatekeeper 识别开发者身份，也不等同于公证。

## 生成 Release 资产

在每个目标架构对应的 macOS 上以 Release 配置构建。脚本只生成当前机器架构的产物；Apple Silicon 和 Intel 包应分别构建，不要把一个架构的二进制误标为另一个架构。

```bash
cd macOS
./scripts/package-release.sh
```

产物位于 `macOS/build/release/`：

- `Todo-macos-arm64.zip` 或 `Todo-macos-x64.zip`
- `SHA256SUMS.txt`

把 ZIP 和校验文件一起添加到 GitHub Release。发布说明应包含下面的未签名提示，并写明该 Release 实际包含哪些架构。

### Release 说明模板

```markdown
## macOS 安装说明

本项目是个人学习项目。macOS 包采用 ad-hoc 签名，没有 Apple Developer ID 签名，也没有经过 Apple 公证。

1. 下载与你的 Mac 架构对应的 ZIP 和 `SHA256SUMS.txt`。
2. 在下载文件所在目录运行 `shasum -a 256 -c SHA256SUMS.txt`，确认校验通过。
3. 解压并将 `Todo.app` 移到“应用程序”。
4. 仅在确认下载来源和校验结果后，在终端运行 `xattr -d com.apple.quarantine /Applications/Todo.app`，然后启动 Todo。

移除 quarantine 不会签名或公证应用，只是清除下载隔离标记。不要对来源不明或校验失败的应用执行此操作。

源码与构建步骤见仓库 README。
```

## 维护者本地检查

上传前检查文件名、架构、校验文件和 ad-hoc 签名状态：

```bash
cd macOS/build/release
shasum -a 256 -c SHA256SUMS.txt
ditto -x -k Todo-macos-arm64.zip /tmp/todo-release-check
codesign -dv --verbose=2 /tmp/todo-release-check/Todo.app
```

Intel 包将文件名替换为 `Todo-macos-x64.zip`。`codesign` 输出应显示 ad-hoc signature 或没有 Apple Developer ID Authority；不得误写为“已公证”或“Apple 签名”。完成后可删除临时解压目录。

SHA-256 能发现文件损坏或 ZIP 与所发布校验文件不一致，但如果攻击者同时替换 ZIP 和校验文件，它不能认证发布者身份。只从项目的 GitHub Release 下载。

## 干净 Mac 验收

在一台没有 Xcode、Swift 工具链和 Todo 旧安装数据的 Mac 上验收发布 ZIP。测试前确认机器架构，并记录 macOS 版本。使用测试飞书账号和可安全恢复的测试记录；不要在反馈中提供 App Secret、OAuth 授权码、令牌或私人任务数据。

### 安装与首次启动

1. 从 GitHub Release 下载目标架构 ZIP 和 `SHA256SUMS.txt`。
2. 在下载目录运行 `shasum -a 256 -c SHA256SUMS.txt`，记录是否显示 `OK`。
3. 解压 ZIP，把 `Todo.app` 拖入“应用程序”。记录 Finder 或首次启动时 macOS 显示的完整 Gatekeeper 提示及可用按钮。
4. 按 README 操作移除隔离标记，再启动 Todo。记录应用是否启动、窗口是否正常显示，以及是否出现额外警告。
5. 第一次连接飞书，输入自己测试应用的 App ID/App Secret。记录 Keychain 访问提示的原文、选项和所选操作；不要截图或复制凭证内容。

### Keychain 持久性

1. 完成一次 OAuth 授权并确认 Todo 能读取测试视图。
2. 退出 Todo 后重新启动，检查是否复用授权身份和凭证，记录是否再次弹出钥匙串提示。
3. 重启 Mac 后再启动 Todo，重复检查。
4. 通过“Todo → 飞书应用凭证…”保存修改后的测试凭证，检查是否要求重新授权、旧令牌是否失效、账号工作区是否仍保留。
5. 登出后检查 App ID/App Secret 是否仍保留在 Todo，且重新连接可再次使用。

### 功能冒烟检查

- 粘贴测试多维表格视图链接，完成字段映射并加载记录。
- 勾选一条可恢复的测试记录，确认飞书状态变化；再撤销并确认恢复原值。
- 关闭并从便签夹重新打开当前便签。
- 断开网络，确认快照显示为过期只读状态；恢复网络后手动刷新。

## 验收反馈记录模板

```text
Mac 芯片/架构：
macOS 版本：
Todo Release 版本：
SHA-256 校验：通过 / 失败
Gatekeeper 提示及操作：
首次 Keychain 提示及所选选项：
首次授权结果：
退出再启动后是否重复询问：
重启 Mac 后是否重复询问：
凭证更换/登出行为：
读取/写回/撤销结果：
可复现问题步骤：
```

## 故障反馈原则

- 校验失败：不要启动该包；重新下载并报告 Release 版本和校验结果。
- `xattr` 报告没有 quarantine 属性：记录提示后直接尝试启动，不需加 `sudo`。
- Gatekeeper 仍阻止启动：保留完整提示文本，先确认下载 URL、架构和校验和，不要用其他清除系统安全属性的命令。
- Keychain 每次都提示：记录是选择“允许”还是“始终允许”、是否重启过应用/系统、Todo 是否被移动或覆盖安装，以及当前 Release 版本。
- 若更新版本触发新的 Keychain 提示，记录旧版与新版版本号及操作步骤，作为后续改进依据。
