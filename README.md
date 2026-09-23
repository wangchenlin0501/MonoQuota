# MonoQuota · Codex 双额度

一款简洁的 macOS 菜单栏应用，以两排显示 Codex **5 小时和周额度的剩余百分比**。点击菜单栏项可打开详细面板，查看两项额度的进度条、具体重置时刻和剩余倒计时。面板中的设置按钮允许 5h 和 Week 分别选择「仅数字」「进度条 + 数字」或「仅进度条」。支持手动刷新，每 60 秒自动更新。

在 macOS 26 及更高版本上，详细卡片使用系统 Liquid Glass 效果；较早版本使用系统材质背景。

数字和进度条都表示**剩余额度**，与 Codex 用量页面一致。读取失败时显示 `--`，不会将旧数据冒充实时额度。

## 运行条件

- Apple Silicon Mac、macOS 14 或更高版本
- 已安装并登录 ChatGPT/Codex 桌面应用
- 从源码构建时需要 Xcode 命令行工具

应用通过本机 Codex App Server 的 `account/rateLimits/read` 读取额度，不索取 API Key，也不读取浏览器 Cookie。它使用已安装的 ChatGPT/Codex 应用自带的 Codex 程序。

## 构建与安装

```sh
./build.sh
ditto build/MonoQuota.app /Applications/MonoQuota.app
open /Applications/MonoQuota.app
```

源码构建采用临时签名，未经过 Apple 公证。如果 macOS 阻止首次打开，请在「系统设置 → 隐私与安全」中选择「仍要打开」。

点击菜单栏项，再点击面板右下角的设置按钮，即可分别设置两排。选择会保存在本机偏好设置中。

## 许可证

[MIT](LICENSE)。允许按许可证条款进行商用、修改和再分发。

这是独立的社区项目，与 OpenAI 没有关联。
