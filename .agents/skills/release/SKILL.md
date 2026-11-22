---
name: release
description: 准备或发布 AGY Switcher macOS 新版本。用于“发版”“发布 vX.Y.Z”“准备双语 release notes”或预览本次发布内容。按代码改动选版本，生成中英文产品更新说明，按授权推送 tag 并跟踪签名发布。
---

# 发布 AGY Switcher

预览请求只交付版本建议和双语草稿。用户明确要求发布当前版本时，完成本页全部步骤。

## 确定版本

在仓库根目录执行 `git fetch origin --tags --prune`。运行 `python3 .github/scripts/release.py plan`，取得上一版 tag 和建议版本。用户给了确切版本就加 `--version X.Y.Z`，给了升级级别就加 `--bump major|minor|patch`。如果指定版本无效或已使用，指出冲突，让用户决定新的版本。

阅读上一版 tag 到 `HEAD` 的提交和实际 diff，重点核对 `App/`、`Sources/` 和会影响使用体验的构建配置。首发从当前完整产品核对功能，缺省版本为 `0.1.0`。后续版本以实际产品变化决定升级级别。需要用户迁移或打破向后兼容时用 major，新增功能用 minor，修复、兼容性维护及内部改动用 patch。脚本根据 Conventional Commits 提供初步建议，实际 diff 与建议有出入时用 `--bump` 纠正。

## 写双语更新说明

在 `docs/release/` 下写 `vX.Y.Z.md` 和 `vX.Y.Z_zh-CN.md`。以用户遇到的问题、看到的变化或能完成的操作为单位合并条目。两种语言覆盖相同的功能、限制和迁移步骤，界面名称与实际本地化文案一致。跳过纯重构、CI、测试及提交细节。仅内部维护时可以简短说明本版无可见功能变化。首发说明可用场景、主要功能和系统要求。

用 `gh repo view --json nameWithOwner --jq .nameWithOwner` 取得 GitHub 仓库名，顶部语言链接固定到本次 tag。英文第一行和中文第一行分别使用以下格式，替换 `OWNER/REPO` 和 `vX.Y.Z`。

```markdown
**English** | [简体中文](https://github.com/OWNER/REPO/blob/vX.Y.Z/docs/release/vX.Y.Z_zh-CN.md)
```

```markdown
[English](https://github.com/OWNER/REPO/blob/vX.Y.Z/docs/release/vX.Y.Z.md) | **简体中文**
```

有上一版时，可在两份说明的末尾加上相同的 GitHub compare 链接。执行 `python3 .github/scripts/release.py check-notes vX.Y.Z --repository OWNER/REPO`。

## 推送和确认发布

1. 确认这次发布从干净且已与 `origin/main` 同步的产品提交开始。工作区有无关变更时保留它们，在干净的检出中准备发版。用 `gh secret list` 确认 README 列出的五个签名和公证 Secrets 已配置。运行 `swift test`。
2. 只暂存两份说明，提交 `chore: release vX.Y.Z`。正式构建的版本号由 tag 注入 Xcode。以本地 GitHub 写入身份创建 annotated tag 并原子推送本次提交和 tag。若 `main` 需要走 PR，合并说明后在远端的合并提交打 tag，核对该提交与更新说明覆盖的产品改动一致。

   ```sh
   git tag -a vX.Y.Z -m "AGY Switcher vX.Y.Z"
   git push --atomic origin HEAD:refs/heads/main refs/tags/vX.Y.Z:refs/tags/vX.Y.Z
   ```

3. 用 `gh run list --workflow release.yml --branch vX.Y.Z --event push` 等待本次 run 出现，核对其提交，再用 `gh run watch RUN_ID --exit-status` 跟到结束。CI 从 tag 读取说明，在签名和公证后上传 DMG，再公开 Release。通过 `gh release view vX.Y.Z --json url,isDraft,body,assets` 确认说明、中文链接、DMG 和发布状态，返回 Release 链接。
4. 失败后用 `gh run view RUN_ID --log-failed` 定位。签名配置或服务端的临时问题修正后，重跑同一个 run。若需要改 tag 里的代码或说明，修正后发新版本。保留现有 tag 和已公开的产物。
