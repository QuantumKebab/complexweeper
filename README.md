# 复扫雷 Complexweeper · Android 版

把 [青月晓 / complexweeper](https://github.com/Yueqing-Chen/complexweeper) 这个 Zig + Win32 原生 Windows 扫雷变体，移植成可以在 Android 5 及以上直接安装运行的原生应用。

![platform](https://img.shields.io/badge/platform-Android%205.0%2B-3ddc84)
![minSdk](https://img.shields.io/badge/minSdk-21-blue)
![abi](https://img.shields.io/badge/ABI-arm64--v8%20%7C%20armeabi--v7a%20%7C%20x86__64%20%7C%20x86-lightgrey)
![license](https://img.shields.io/badge/license-GPL--3.0-orange)

安装包见 [Releases](../../releases)：`复扫雷-Android-1.2.0.apk`（3.2 MiB，已签名，可直接安装）。

---

## 这是什么游戏

玩法与经典扫雷一致：点击翻开格子、长按插旗、同按相邻两格批量翻开，翻开后靠数字推断雷的位置。

区别在于**格子上显示的数字是复数**——同时带实部与虚部，而不是一个整数邻雷数。对应两套判据：

| 模式 | 说明 |
| --- | --- |
| 圆复型 | 按圆形邻域/复数模长判定 |
| 闵可夫斯基型 | 按闵可夫斯基距离判定 |

两种模式各自维护三档难度的独立最高分记录。四种雷型的命名与具体判定规则沿用上游实现，进游戏后可在「帮助」页查看完整规则说明。

## 功能特性

- **三种预设难度**：初级 9×9（10 雷）、中级 16×16（40 雷）、高级 30×16（99 雷）
- **自定义雷区**：宽 9–40、高 9–30，带完整的参数校验与错误提示
- **两种判据模式**：圆复型 / 闵可夫斯基型
- **画面缩放**：适应屏幕 / 150% / 200% / 300% / 400%，放大后单指拖动平移（小盘面格子过小时不用再担心误触）
- **完整操作**：点击翻开、长按插旗（380 ms）、插旗模式、同按相邻两格批量翻开、顶栏重开
- **最高分记录**：两种模式 × 三档难度
- **帮助 / 关于**：规则说明可滚动查看
- **存档**：退出后自动保存进度，重新进入继续上一局
- **纯原生**：无 WebView、无 Java/Kotlin 代码，界面自绘，不依赖系统 UI 控件

## 操作方式

| 操作 | 作用 |
| --- | --- |
| 点击未翻开的格子 | 翻开（插旗模式下改为插旗） |
| 长按格子（380 ms） | 插旗 / 取消插旗 |
| 顶栏「插旗」 | 切换插旗模式，此模式下轻点即插旗 |
| 同时按住两个相邻数字格 | 批量翻开周围（已插够旗时） |
| 顶栏「缩小 / 放大」 | 画面缩放，每点一次变一档 |
| 放大后单指拖动 | 平移画面 |
| 顶栏「菜单」 | 难度、模式、缩放、自定义雷区、最高分、帮助、关于、静音 |
| 顶栏「重开」 | 重开本局 |

## 安装

1. 下载 Releases 里的 `复扫雷-Android-1.2.0.apk`
2. 手机上允许「安装未知来源应用」后点击安装
3. 系统要求：**Android 5.0（API 21）及以上**，竖屏

APK 内含四种 ABI，主流机型均可直接安装。

## 从源码构建

### 依赖

| 组件 | 版本 |
| --- | --- |
| [Zig](https://ziglang.org/) | 0.14.1 |
| Android SDK Build-Tools | 34.0.0 |
| Android NDK | r26b |
| JDK | 17（仅用于 apksigner） |

### 构建

```bash
export ANDROID_SDK_ROOT=/path/to/sdk
export ANDROID_NDK_ROOT=/path/to/ndk
./android/build.sh
```

脚本会依次完成：Zig 编译游戏逻辑为各 ABI 的目标文件 → NDK clang 编译并链接 C 平台层与 `native_app_glue` → `aapt2` 编译资源并链接 → 放入 `lib/<abi>/libcomplexsweeper.so` 并做 16 KB 页对齐 → `zipalign` → `apksigner` 签名（首次运行自动生成 `debug.keystore`）。

产物位于 `android/build/complexsweeper.apk`。

> 注意：Zig 0.14.1 无法为 Android 目标提供 libc，因此走「Zig 编译为 object，再由 NDK clang 链接」的路径。

### 主机侧自检

移植过程中把游戏逻辑编译到桌面端跑断言，用来验证界面几何与交互：

```bash
cd work/host
zig build-obj android_main.zig -O ReleaseSafe -fPIC -femit-bin=am_host.o
zig cc -O1 -o host host_main.c platform_host.c am_host.o -lm
./run.sh
```

## 项目结构

```
android/
  AndroidManifest.xml        NativeActivity 声明（minSdk 21 / targetSdk 34 / 竖屏）
  build.sh                   四 ABI 构建 + 资源 + 对齐 + 签名
  app/
    res/                     字符串资源与五档自绘图标
    src/
      android_main.zig       游戏逻辑、界面绘制、布局、触摸、存档
      platform.c             NativeActivity / EGL / GLES2 / 触摸 / OpenSL ES / zlib / 文件
      platform.zig           平台层接口
      softfb.zig             软件帧缓冲（填充、立体边框、最近邻贴图）
      quad_verts.h           矩形顶点表（设备端与自检共用）
      ui_assets.zig          界面图集索引
      game.zig               规则层
      ui.bin.z / atlas.bin / sounds.bin   界面图集、棋盘素材、音效（压缩内嵌）
scripts/
  gen_ui_atlas.py            由中文字体生成界面图集
work/host/                   桌面端自检 harness
```

## 实现要点

- **渲染**：所有界面（棋盘、面板、按钮、文字）先画进一块 RGBA 软件帧缓冲，再整块作为纹理上传，用一个批次提交的顶点缓冲 + 一个着色器上屏。Win32 版的 `fill` / `DrawEdge` / `StretchBlt` 对应到 `softfb.zig` 里的填充、立体边框与最近邻缩放。
- **清晰度**：内部渲染倍率按目标格子像素自动选取，缩放时保证放大后依然锐利；客户区与界面图集的尺寸都控制在 2048 以内，兼容 `MAX_TEXTURE_SIZE` 只有 2048 的机型。
- **输入**：`native_app_glue` 的输入队列在 C 层换算成屏幕坐标，长按判定、拖动平移与点击的区分都在游戏层处理。
- **素材**：棋盘素材沿用上游的 `atlas.bin`（GDI 32bpp DIB 顺序，装载时做一次 R/B 交换），界面图集由 `scripts/gen_ui_atlas.py` 从系统中文黑体现场生成。

## 验证情况

| 项目 | 结果 |
| --- | --- |
| 界面 / 交互自检（桌面 harness） | 81 项断言全过 |
| 规则自检（上游自带用例） | 58 项全过 |
| 主机侧渲染图目视核对 | 26 张界面 PNG |
| 真机运行 | 已在 Android 真机安装试玩，功能正常 |
| APK 静态验收 | minSdk 21、四 ABI、签名 v1+v2、无 TEXTREL、16 KB 页对齐 |

## 已知限制

- 仅竖屏。超宽盘面（如 40 列）建议用顶栏「放大」按钮放大后拖动查看。
- **双指捏合缩放尚未实现**，目前缩放靠顶栏按钮与菜单档位。
- 音效走 OpenSL ES，在部分机型上可能与系统媒体音量策略不同步。

## 素材与授权

- **上游项目**：[Yueqing-Chen/complexweeper](https://github.com/Yueqing-Chen/complexweeper)（作者 青月晓），采用 **GPL-3.0**。本仓库是它的 Android 移植，属衍生作品，同样以 **GPL-3.0** 发布。
- **棋盘素材与音效**：包含 Microsoft 扫雷（Minesweeper）的版权素材，版权归 Microsoft 所有。上游项目在 GPL-3.0 下分发这些素材，本移植沿用。**如需商用，请自行确认授权，或替换为自绘素材。**
- 界面文字与图标：中文字形由系统字体 `Noto Sans CJK` 生成，图标为本项目自绘。

## 致谢

- [青月晓](https://github.com/Yueqing-Chen) —— 上游 Windows 版复扫雷的作者，游戏规则、界面文案与素材均来自该项目
- [Zig](https://ziglang.org/)、Android NDK、`native_app_glue`

## 许可证

[GPL-3.0](LICENSE) —— 与上游保持一致。
