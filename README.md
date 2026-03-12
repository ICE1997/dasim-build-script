# PowerShell 构建流水线（标准化 + 简化 JSON）

配置分三层：

1. `tools`：构建工具配置（工具路径、依赖目录、git 凭据）
2. `build/release/upload`：阶段参数（顺序固定 `build -> release -> upload`）
3. `projects[]`：项目源码、构建方式、产物收集规则

## 最简配置骨架

```json
{
  "tools": {
    "git": { "path": "...", "username": "...", "password": "..." },
    "maven": { "path": "...", "dependencyDir": "D:/offline-deps/m2-repository", "settingsXml": "./maven/settings.xml" },
    "npm": { "path": "...", "dependencyDir": "D:/offline-deps/npm-cache" },
    "cmake": { "path": "..." },
    "sevenZip": { "path": "..." },
    "innoSetup": { "path": "..." }
  },
  "paths": { "workspace": "./workspace", "output": "./output", "package": "./packages", "dependencies": "D:/offline-deps", "logs": "./logs" },
  "version": "1.2.3",
  "build": { "enabled": true, "projects": [], "parallel": { "enabled": true, "maxWorkers": 3 } },
  "release": {
    "enabled": true,
    "bump": "patch",
    "productName": "dasim",
    "volumeSize": "500m",
    "exclude": ["*.tmp"],
    "inno": {
      "enabled": true,
      "appName": "Dasim",
      "publisher": "Dasim Team",
      "dataMode": "external",
      "maxDataPackageSize": "4096M",
      "scriptTemplatePath": "./inno/setup-template.iss"
    }
  },
  "upload": { "enabled": true, "uploadSha256": true, "ftp": { "url": "...", "username": "...", "password": "..." } },
  "projects": []
}
```


## 标准化约定（脚本/结构/配置）

- 路径标准化：`paths.*` 支持相对路径，统一按 `-ConfigPath` 所在目录解析为绝对路径，避免受当前工作目录影响。
- 配置预校验：加载配置时会进行基础校验（`parameters.paths`、`projects[].id` 唯一、`projects[].build.tool` 合法）。
- 上下文结构统一：入口脚本统一通过 `New-PipelineContext` 构造运行上下文，避免重复定义。
- 单项目包装脚本统一：`build-backend.ps1` / `build-frontend.ps1` / `build-cpp.ps1` 统一启用 `Set-StrictMode` 与 `Stop` 策略。


## tools 规范（路径 + 依赖 + 凭据）

- 推荐使用对象格式：`tools.<name>.path`。
- 构建**具体参数**（如 maven/npm/cmake 的 args）建议放在 `projects[].build.*`，按项目维护。
- 依赖目录可由工具自定义（如 Maven/NPM）：`tools.<tool>.dependencyDir`。
- `tools.maven.settingsXml`：Maven 全局 `settings.xml` 路径（相对仓库根目录或绝对路径）。
- Git 凭据放到 `tools.git.username/password`（项目级仓库配置仍可覆盖）。

## Maven 项目说明

`build.tool = "maven"` 时支持：

- `args`：Maven 构建附加参数（项目级）。

## npm 项目说明

`build.tool = "npm"` 时支持：

- `args`：`npm run <script>` 的附加参数（项目级）。
- `ciArgs`：`npm ci` 的附加参数（项目级）。
- `skipCi`：是否跳过 `npm ci`。
- `nodeModulesLinks`：将依赖目录中的 node_modules 链接到项目目录或子目录（支持多个）。

## 打包命名与排除

release 阶段默认包名规则：

`产品名称_两位年份R季度_年份月日.7z`

例如：`dasim_24R3_20240930.7z`

可配置：
- `release.productName`：产品名称
- `release.volumeSize`：分卷大小
- `release.exclude`：7z 打包排除规则（转换为 `-xr!`）

> 如果显式配置 `release.packageName`，则优先使用该包名。

## 额外安装包（Inno Setup）

在保留 7z 直接压缩的同时，支持额外生成 Inno Setup 安装包：

- `release.inno.enabled = true`：启用
- `release.inno.dataMode`：`external`（数据外置）或 `embedded`（数据内嵌）
- `release.inno.maxDataPackageSize`：单数据包上限，脚本会约束为不超过 `4096M`（4G）
- `release.inno.scriptTemplatePath`：`.iss` 模板路径（默认 `./inno/setup-template.iss`）

说明：
- 启用后必须基于 `.iss` 模板生成最终脚本并调用 `tools.innoSetup`（ISCC）编译（模板缺失会报错）。
- 生成的安装包文件也会纳入同一份 `.sha256` 并参与 upload。

## 产物收集（JSON 驱动）

```json
"collect": {
  "targets": [
    { "source": "dist", "destination": "frontend", "exclude": ["*.map"], "cleanDestination": true }
  ]
}
```

## 阶段说明

- `build`：多项目（可并行）构建 + 产物收集
- `release`：生成 `buildInfo.json`（包含全部项目 commitId）、版本升级、7z打包、可选Inno安装包、sha256
- `upload`：FTP 上传压缩包及可选 sha256（需要配置 `upload.ftp.url/username/password`）

## 使用

```powershell
pwsh ./build-all.ps1 -ConfigPath ./build-config.json
pwsh ./build-project.ps1 -ConfigPath ./build-config.json -ProjectId backend
pwsh ./publish-output.ps1 -ConfigPath ./build-config.json
```
