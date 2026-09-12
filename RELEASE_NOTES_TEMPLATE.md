<!--
  RELEASE_NOTES_TEMPLATE.md — copy to RELEASE_NOTES.md and fill in per release.
  publish.sh reads RELEASE_NOTES.md from repo root as the GitHub Release body.

  Sections to include (in order):
    EN: What's new → Env vars → Install → Paper → Tested
    ZH: 更新说明 → 环境变量 → 安装 → 技术报告 → 测试

  Badges are auto-verified by publish.sh (checks URLs resolve before publishing).
-->

## What's new in {{VERSION}}

### [Feature Area 1]
- **Bold key change** — one-line description + why it matters.

### [Feature Area 2]
- Detail line.

### New environment variables (if any)
| Variable | Default | Purpose |
|---:|---:|---|
| `OMLX_WATCHDOG_XXX` | `value` | What it does (since vN) |

### One-click install
```bash
curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
```

### Technical report (EN + 中文)
- **English:** [paper-technical-report-en.pdf](https://github.com/ricky8848/omlx-watchdog/releases/download/{{TAG}}/paper-technical-report-en.pdf)
- **中文:** [paper-technical-report-zh-CN.pdf](https://github.com/ricky8848/omlx-watchdog/releases/download/{{TAG}}/paper-technical-report-zh-CN.pdf)
- **DOI:** [10.5281/zenodo.22675074](https://doi.org/10.5281/zenodo.22675074)
- **Zenodo:** [record 22675074](https://zenodo.org/records/22675074)

### Tested
[One-line summary of test coverage for this release.]

---

## {{VERSION}} 更新说明（中文）

### [功能区域 1]
- **关键变更** — 一句话描述 + 为什么重要。

### [功能区域 2]
- 详细说明。

### 新增环境变量（如有）
| 变量 | 默认值 | 用途 |
|---:|---:|---|
| `OMLX_WATCHDOG_XXX` | `value` | 功能说明（vN 起） |

### 一键安装
```bash
curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
```

### 技术报告（EN + 中文）
- **English:** [paper-technical-report-en.pdf](https://github.com/ricky8848/omlx-watchdog/releases/download/{{TAG}}/paper-technical-report-en.pdf)
- **中文:** [paper-technical-report-zh-CN.pdf](https://github.com/ricky8848/omlx-watchdog/releases/download/{{TAG}}/paper-technical-report-zh-CN.pdf)
- **DOI:** [10.5281/zenodo.22675074](https://doi.org/10.5281/zenodo.22675074)
- **Zenodo:** [record 22675074](https://zenodo.org/records/22675074)

### 测试
[本版本测试覆盖摘要。]
