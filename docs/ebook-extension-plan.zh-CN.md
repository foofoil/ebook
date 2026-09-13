# EBook（EPUB）扩展实施计划

本文以 2026-09-13 的相邻 `extension-kit`、`hifi`、`foofoil` 工作树为实施基线；`ebook` 当前只有本方案，尚无 Swift 包或运行时实现。下文路径除特别说明外均相对于对应项目根目录。实施时遵守各项目 `AGENTS.md`；本文中的边界值是 v1 产品限制，修改时须同步实现、测试与 README。

## 0. 目标与已确认决策

目标：建立第一方 foofoil 扩展 `ebook`，本次只支持 EPUB 格式：

- 一个箔（窗口）同一时间只打开一个 EPUB 文件；
- 侧边目录面板显示 EPUB 目录（树形），点击目录跳转章节；
- 正文以富文本（HTML）方式呈现，接近真实阅读体验。

已确认决策：

- **富文本方案**：新增 `document` presentation 契约，宿主用 `WKWebView` 渲染章节 HTML；跨 `extension-kit`、`ebook`、`foofoil` 三个仓库实施。
- **命名**：
  - Extension ID：`app.foofoil.extension.ebook`
  - Provider ID：`ebook.epub`
  - Bundle：`EBook.foofoilextension`
  - 模块：`EBookExtensionCore` / `EBookExtensionRuntime`
- **调试注入**：`foofoil/run` 同时构建并注入 `../hifi` 与 `../ebook` 的开发插件。
- **单文件约束**：扩展一个会话只接受一个 `.epub`；同一箔内再次打开会按宿主既有行为关闭旧会话并替换。
- **侧边目录**：复用现有 `ui.navigator` 树形面板与 `ui.navigator.action`，不新增扩展私有侧栏。
- **阅读可达性**：书籍目录之外，提供按 spine 顺序排列的“全部章节”分组，确保每个支持的正文项都可访问；目录动作支持章节内锚点。
- **恢复**：支持重启后重新打开原书并生成首章；v1 不保存章节或滚动位置。`restore` 作用于宿主已创建的活会话，不创建第二个会话。

## 1. 现状与关键约束

- 扩展与宿主的稳定边界是 C ABI（`foofoil_extension_create`）与 JSON 值消息；不跨边界传 `NSView` / SwiftUI `View` / 进程内对象。
- 宿主 `ExtensionPresentationView` 目前只支持 `.text` 与 `.unavailable`，扩展会话没有文档/HTML 渲染路径，因此富文本必须新增 presentation 契约与宿主视图。
- 宿主已有通用 `NavigatorPanelView`：支持 `ui.navigator` 的 `flat` / `outline` 两种样式、`parentID` 层级、`isCurrent` 选中态，并通过 `ui.navigator.action` 把行点击路由回扩展。
- 宿主 `ExtensionStateStore` 对会话 payload 有 **1 MiB** 上限，且每次目录动作都会重新持久化整个 `ContentSession`。因此章节 HTML **不能**放进 presentation，只能放本地文件 URL。
- `hifi` 是扩展的参考实现：独立 Swift 包、`ExtensionManifest.json`、`Bundle/Info.plist`、`build-plugin`、`foofoil_extension_create`，且不依赖 `extension-kit`（自己用 `JSONSerialization` 拼 JSON）。
- 宿主默认扩展会话来自 DEBUG 的 `./run` 注入；`foofoil/run` 当前只处理 `../hifi`。
- `NavigatorItem` 的 `isEnabled` / `isCurrent` 都是必填 JSON 字段；Swift 初始化器默认值不等于 Codable 缺省值。
- 宿主恢复路径是 `open(savedSession.request)` → `restorePlayback(from:in:)`，后者向 fresh session 发送 `session.lifecycle`。参照 `foofoil/AppState/AppState+ContentOpen.swift`、`foofoil/ExtensionSupport/Runtime/ExtensionSessionLifecycle.swift`。
- 宿主在后台执行扩展调用，`ExtensionLoader` 用每个 runtime 的 `callLock` 串行化 C ABI；同一 runtime 服务多个窗口。目录动作的宿主异步入口还需按第 4.3 节保证提交顺序和过期回包隔离。
- 现有 `ebook` 目录尚不是独立 Git 仓库。创建 Swift 包与文件即可，不把初始化仓库、发布扩展或修改系统文件关联列为本次必要步骤。

## 2. extension-kit（契约层）

### 2.1 `SessionPresentation` 新增 `document`

文件：`Sources/FoofoilExtensionKit/ContentSession.swift`

```swift
public enum SessionPresentation: Codable, Equatable, Sendable {
    case text(titleKey: String, body: String)
    case document(url: URL)                 // 新增
    case unavailable(titleKey: String, messageKey: String)
}
```

JSON 形态（`ContentSession.presentation`）：

```json
{ "kind": "document", "url": "file:///..." }
```

- 此代码块只展示 public case；必须同步修改已有手写 `CodingKeys`、`Kind`、`init(from:)` 和 `encode(to:)`，不能改用 Swift enum 自动编码。
- `url` 必须是本机绝对文件 URL，无远端 host、用户名、密码或 query；允许 fragment，表示章节内锚点。文件由扩展生成且不可原地修改，随活会话生命周期有效。
- URL 的文件身份是去除 fragment 后的规范化路径；呈现身份是包含 fragment 的完整 URL。fragment 通过 `URLComponents` 编码，禁止字符串拼接与二次解码。
- 宿主验证文件存在且为普通 HTML 文件、非符号链接，并要求其位于本体进程临时目录之下（完整规则见第 4.1 节）；`loadFileURL(_:allowingReadAccessTo:)` 的读权限只授予该 HTML 文件本身，因为文档资源全部内联。不得授权原 EPUB 所在目录或整个临时目录。
- 禁用 JavaScript，并在首次加载前安装第 4.1 节规定的资源拦截与导航策略；不能把禁用 JS 当作禁止网络。
- 旧 `text` / `unavailable` 编码保持不变；新增 case 不会影响现有 fixture 解码。

### 2.2 契约文档

新增：`docs/document-presentation-v1.zh-CN.md`

内容要点：

- 能力范围：`document` presentation 是会话级呈现，不需要额外 capability 声明；
- 生命周期：文件由扩展创建、更新、删除；会话关闭后宿主不得再引用旧 URL；
- 安全：禁用脚本与远端加载；URL 非法（非 `file:`）时宿主必须拒绝并显示占位；
- 不携带任何扩展私有 View，宿主负责呈现。
- 跨版本范围：与更新后的宿主和 kit 同步交付；不宣称旧宿主能解码新 `document`。依照当前项目规则不添加旧宿主兼容层，也不新增 EPUB 专用 capability。
- 明确 fragment、不可变文件、加载错误、首次加载阻断及视图销毁语义，引用第 4.1 节的通用实现约束，不把 EPUB 解析规则写入共享契约。

### 2.3 契约测试

文件：`Tests/FoofoilExtensionKitTests/ContractTests.swift`

- 新增 `SessionPresentation.document` 的 Codable round-trip；
- 直接解码原始 JSON `{"kind":"document","url":"file:///tmp/chapter.html"}` 并断言 URL；
- 保留既有 text/unavailable 与旧会话解码用例。
- 加入含 Unicode／百分号编码 fragment 的 URL round-trip；非法 URL 的拒绝由宿主策略测试覆盖。
- 加入完整 document 会话 fixture，含两级目录、显式布尔值，执行 `ContentSession` 解码和现有 navigator validator。新增“缺失 `isCurrent` 解码失败”的用例，防止 JSON 手写端再次漏字段。

验证：`cd extension-kit && swift test`。

## 3. ebook（新 Swift 包）

### 3.1 目录结构

```text
ebook/
├── Package.swift
├── ExtensionManifest.json
├── Bundle/Info.plist
├── build-plugin
├── README.md
├── .gitignore
├── docs/
│   └── ebook-extension-plan.zh-CN.md
├── Sources/
│   ├── EBookExtensionCore/
│   │   ├── ZIPArchive.swift
│   │   ├── EPUBContainer.swift
│   │   ├── EPUBPackage.swift
│   │   ├── EPUBTableOfContents.swift
│   │   ├── EPUBChapterRenderer.swift
│   │   ├── EPUBDocument.swift
│   │   ├── EPUBLimits.swift
│   │   └── EPUBError.swift
│   ├── EBookExtensionRuntime/
│   │   ├── Runtime.swift
│   │   ├── NavigatorActionMessage.swift
│   │   └── SessionLifecycleMessage.swift
│   ├── EBookInspect/main.swift
│   └── EBookRuntimeSmoke/main.swift
└── Tests/
    └── EBookExtensionCoreTests/
```

### 3.2 `Package.swift`

- `swift-tools-version: 6.0`，`platforms: [.macOS(.v15)]`。
- Products：
  - `.library(name: "EBookExtensionCore", targets: ["EBookExtensionCore"])`
  - `.library(name: "EBookExtensionRuntime", type: .dynamic, targets: ["EBookExtensionRuntime"])`
  - `.executable(name: "ebook-inspect", targets: ["EBookInspect"])`
  - `.executable(name: "ebook-runtime-smoke", targets: ["EBookRuntimeSmoke"])`
- 目标：Core、Runtime、两个可执行、`EBookExtensionCoreTests`。Core 依赖 Foundation / Compression，Runtime 依赖 Core；Runtime 的 C ABI 导出和 JSON 编解码沿用 hifi 模式，不引入宿主 Swift 类型。
- 声明第一方本地 package 依赖 `.package(path: "../extension-kit")`，仅供 smoke／契约测试依赖 `FoofoilExtensionKit` 和 `FoofoilExtensionABI`；生产 Core/Runtime 不依赖它。smoke 经真实 ABI 获取字节，再使用 kit 解码和校验，不以字典字段检查替代契约验证。`build-plugin` 只构建 `EBookExtensionRuntime` product，交付的 dylib 不得链接 kit；该项在脚本与 `otool -L` 检查中验证。
- 不引入任何第三方依赖；ZIP/HTML 使用系统框架（`Foundation`、`Compression`）。

### 3.3 `ExtensionManifest.json`

```json
{
  "id": "app.foofoil.extension.ebook",
  "name": "EBook",
  "version": "0.1.0",
  "extensionAPI": { "min": 1, "max": 1 },
  "system": { "minMacOS": "15.0", "architectures": ["arm64"] },
  "providers": [
    {
      "id": "ebook.epub",
      "role": "primary",
      "contentTypes": [
        { "extensions": ["epub"], "strategy": "extension" }
      ]
    }
  ],
  "capabilities": [
    { "id": "ui.navigator", "contractVersion": 1, "scope": "presentation" },
    { "id": "ui.navigator-actions", "contractVersion": 1, "scope": "presentation" },
    { "id": "session.lifecycle", "contractVersion": 1, "scope": "session" }
  ]
}
```

说明：EPUB 不设置 `contentFamily`（现有枚举只有 audio/video/image），宿主走通用扩展呈现路径。

### 3.4 `Bundle/Info.plist` 与 `build-plugin`

- `CFBundleIdentifier = app.foofoil.extension.ebook`
- `CFBundleExecutable = EBookExtensionRuntime`
- `CFBundleName = EBook`
- `FoofoilExtensionExecutionModel = inProcess`
- `build-plugin`：复用 hifi 脚本模式，把 `libEBookExtensionRuntime.dylib` 拷为 `Contents/MacOS/EBookExtensionRuntime`，产出 `EBook.foofoilextension`。
- 参数保持 `<output-root> <sign-identity>`；使用 ebook 独立 scratch 路径，复制 manifest 到 `Contents/Resources/ExtensionManifest.json`，签署插件并执行 `plutil -lint`。脚本必须可执行。不要复制 Hi-Fi 的 bundle ID、可执行名或 scratch 目录。

### 3.5 Core：EPUB 解析

**ZIPArchive.swift**

- 解析 EOCD、单卷 ZIP64 EOCD/locator 与中央目录的 ZIP64 extra 字段，建立 `path → (offset, compressedSize, uncompressedSize, method, crc32)` 索引。拒绝分卷、ZIP 加密标志及不支持的压缩方法；不把所有 ZIP64 包笼统接受为“基础支持”。
- 支持 method 0（stored）与 method 8（deflate）；使用 Compression 的 `COMPRESSION_ZLIB` raw DEFLATE，检查流结束、输出长度和 CRC32。支持 general-purpose bit 3 的 data descriptor：大小以中央目录为准，data 起点由 local header 长度计算，不把 descriptor 当正文。
- 按需读取单个 entry，不整包解压；检查整数溢出、所有 offset/size 在文件范围内、local/central entry 身份一致。entry 路径拒绝绝对路径、NUL、反斜杠、符号链接条目和越过包根的 `..`；规范化重名拒绝。文件名支持 UTF-8 和可验证的 Unicode path extra，纯 ASCII 可直接接受，其余不明编码明确报错。
- `encryption.xml` 属于 EPUB 资源层，由 Document 解析算法和 CipherReference；不能仅凭文件存在判定 DRM。仅含字体混淆（IDPF `http://www.idpf.org/2008/embedding` 或 Adobe `http://ns.adobe.com/pdf/enc#RC`）且目标为 manifest 字体时，v1 跳过这些字体并使用系统字体；其它加密／未知算法返回 `EBook Encrypted Unsupported`。损坏的 encryption.xml 返回无效 EPUB 错误，不静默忽略。

**EPUBContainer.swift**

- 读取 `mimetype`（尽量校验 `application/epub+zip`，允许不合规包继续）。
- 解析 `META-INF/container.xml` 的 `rootfile full-path`，解析相对路径为 ZIP 内绝对路径。
- 选择首个媒体类型为 `application/oebps-package+xml` 的 rootfile；无可用 rootfile 明确失败。所有 XML（container、OPF、nav、NCX、encryption、XHTML、SVG）统一拒绝外部实体和外部 DTD；不得通过 XML 解析触发文件或网络读取。

**EPUBPackage.swift**

- 解析 OPF：`metadata`（`dc:title` / `dc:creator` / `dc:language`）、`manifest`（id/href/media-type/properties）、`spine`（itemref、`toc` 属性）。
- 记录每个 manifest item 的 ZIP 路径与媒体类型；spine 顺序即章节顺序。
- 所有包内引用使用同一个路径解析器：先拆 query/fragment，再按引用文件目录解析；允许合法 `../`，拒绝越过包根、外部 scheme/host、query 和编码后逃逸，百分号只解码一次。CSS 引用相对于 CSS 文件，不能相对于 XHTML 文件。
- v1 正文媒体类型支持 `application/xhtml+xml`；空 spine、缺失 idref、重复 manifest ID 或不支持的正文类型明确报错。保留 `linear="no"` 项供“全部章节”访问；首章选择第一项 linear 正文，无 linear 项时取第一项。

**EPUBTableOfContents.swift**

- 优先 EPUB3 nav（manifest item `properties` 含 `nav`，取 `<nav epub:type="toc">`）。
- 回退 EPUB2 NCX（spine `toc` 指向的 item，或 media-type 为 `application/x-dtbncx+xml`）。
- 生成树形条目：标题、解析后的 href（拆分 fragment）、子节点；分配稳定 ID（如 `toc:0`、`toc:0.1`）。
- 将 href 解析到 spine 索引（相对 nav/ncx 所在目录）；无法映射的条目保留但 `isEnabled = false`。
- 通过 XML namespace URI 识别元素和属性，不依赖作者使用 `epub` / `dc` 等固定前缀。nav 缺失或解析失败时尝试 NCX；两者都不可用时使用 spine 目录，不让目录错误阻止可解析正文阅读。
- 在 `ebook.toc` 贡献末尾追加禁用的“全部章节”父节点 `spine:root`，其子节点 `spine:<index>` 按 spine 顺序覆盖全部正文项，不受原始目录是否覆盖影响。无有效原始目录时只输出该分组。标题依次取已解析的目录标题、manifest ID、文件名，不为获取标题预渲染全书。
- 该父节点的 `isEnabled = false` 不妨碍展开子节点：当前宿主只有 activate 按钮受 `isEnabled` 限制（`NavigatorPanelView.swift` 的 `.disabled(!row.item.isEnabled ...)`），展开 chevron 不受限；宿主需补回归测试。固定分组标题的本地化见第 3.6 节末尾，不由宿主资源文件承担。初始选中首章的无 fragment 目录项，没有则选对应 spine 节点。
- 备选设计（不阻塞 v1）：把“全部章节”做成第二个 `NavigatorContribution`（宿主已支持多贡献切换器），比在 TOC 内嵌禁用根更独立；若采用，`performCommand` 仍按 `contributionID` 统一校验。
- 整个贡献只允许一个 `isCurrent = true`，且与 `selectedItemIDs` 相同；正文内锚点链接滚动不更新目录选中态，v1 不做滚动位置与目录联动。

**EPUBChapterRenderer.swift**

- 解析 XHTML：把实现中列明的常见命名实体（至少 `nbsp` / `copy` / `reg` / `mdash` / `ndash` / `hellip`）转换为数字实体，保留 XML 内建实体；再用 `XMLDocument` 安全解析。未知实体／解析失败使用第 3.6 节的章节错误呈现，不加载原始未清理 HTML。
- 清理：移除 script、事件属性、iframe/frame、object/embed、base、原始 meta、form 及表单控件、音视频、预取 link；只保留同文件 fragment 的超链接，移除其它 href、download 和 target。保留正文 id 与旧式命名锚点。inline SVG 同样清理，只保留本地 fragment 引用与已内联图片，不允许外部 use/foreignObject。
- 内联：包内 `<link rel="stylesheet">` → `<style>`；处理 style 属性和 style 元素。CSS `url(...)` 只允许解析后的包内图片／非混淆字体，重写为按白名单 MIME 生成的 data URI；移除所有 `@import`，v1 不递归导入 CSS。使用能识别注释、引号、转义及括号的扫描器，不以单个正则承担 CSS URL 安全校验。
- `<img src>` / SVG 图片内联为 data URI；移除 `srcset` / `picture source`，对缺失或超限的装饰性资源移除引用并保留替代文字。内嵌及被引用 SVG 使用相同清理规则并检测引用循环；输入自带的 data URI 不直接信任，v1 移除，只有 renderer 自己生成的白名单资源 data URI 可保留。
- 组装自包含 HTML：`<!DOCTYPE html>` + UTF-8 meta + CSP + viewport + `color-scheme: light dark` + 默认阅读 CSS（行高、最大宽度、图片缩放、语义背景与文本色）。仅从清理后的 DOM 构造内容；renderer 生成的 CSP 插入到所有书籍样式/内容之前。书籍固定颜色导致不可读时，v1 阅读样式优先保证正文背景/文字对比度，实测嵌套元素和表格。
- CSP 至少为 `default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; media-src 'none'; base-uri 'none'; form-action 'none'`。这与宿主拦截共同执行，第 4.1 节不得依赖扩展一定正确清理。
- 输出为字符串，由 Runtime 写入会话临时目录。

**EPUBDocument.swift**

- 门面：`open(url:)` → 元数据 + 目录 + spine 章节；`renderChapter(at:)` → 自包含 HTML。
- 缓存键为 spine 索引，锚点不重复生成 HTML；缺失锚点降级到章节顶部，保留目录选择，不把整章判为不可读。

### 3.6 Runtime：JSON 会话协议

**`createSession`**

- 只接受 `singleFile` 或**单元素** `fileCollection`；资源必须是本机文件 URL，扩展名忽略大小写匹配 `.epub`；其它 request kind、空集合、多个资源或其它后缀返回 `2`（unsupportedRequest）。语法损坏的 JSON 返回 `1`（invalidMessage）。单元素集合成功后仍保留原 request 形态和书签，不丢失恢复信息。
- 解析书签并持有安全范围访问至会话关闭（对齐 hifi 的 `RuntimeResourceAccess`）。
- 解析成功：创建 `…/tmp/foofoil-ebook/<session-uuid>/`，渲染首章 HTML 文件，注册会话，返回会话 JSON。
- 书籍结构解析／文件访问失败：清理已分配文件和安全范围访问，返回带 `.unavailable` presentation 的会话，使用第 4.4 节列明的本地化 key。该错误会话保留原 request 和轻量 runtime 记录，仅激活 `session.lifecycle`，允许 close 和 no-op restore；不声明可操作目录，不填充伪造 mediaPlayback。
- 书籍结构与目录可用、仅首章渲染失败：保留安全范围访问、目录及会话记录，返回 `EBook Chapter Failed`（超限则 `EBook Limit Exceeded`）呈现，允许用户换章；与下述目录动作渲染失败行为一致。
- create 成功回包前注册记录、编码并检查第 3.7 节预算；检查失败时撤销创建并释放资源。正文渲染和 ZIP I/O 不在主线程运行。
- 以下为可解码示例；测试时替换 URL 对应的真实文件，带书签的请求另测 Base64 编码。示例 URL 省略了 `…/<runtime-uuid>/<session-uuid>/` 目录层级，实际路径见“文件与清理”。所有 `NavigatorItem` 必须显式输出 `isEnabled` 和 `isCurrent`：

```json
{
  "id": "00000000-0000-4000-8000-000000000001",
  "extensionID": "app.foofoil.extension.ebook",
  "providerID": "ebook.epub",
  "request": { "kind": "singleFile", "resource": { "url": "file:///tmp/example.epub" } },
  "presentation": { "kind": "document", "url": "file:///tmp/foofoil-ebook/example/chapter-0000.html" },
  "capabilities": [
    { "declaration": { "id": "ui.navigator", "contractVersion": 1, "scope": "presentation", "dependencies": [] }, "state": "active" },
    { "declaration": { "id": "ui.navigator-actions", "contractVersion": 1, "scope": "presentation", "dependencies": [] }, "state": "active" },
    { "declaration": { "id": "session.lifecycle", "contractVersion": 1, "scope": "session", "dependencies": [] }, "state": "active" }
  ],
  "commands": [],
  "navigatorContributions": [
    {
      "id": "ebook.toc",
      "contractVersion": 1,
      "titleLocalizationKey": "Table of Contents",
      "style": "outline",
      "selectionMode": "single",
      "items": [
        { "id": "toc:0", "title": "第一章", "isEnabled": true, "isCurrent": true },
        { "id": "toc:0.1", "parentID": "toc:0", "title": "第一节", "isEnabled": true, "isCurrent": false },
        { "id": "spine:root", "title": "全部章节", "isEnabled": false, "isCurrent": false },
        { "id": "spine:0", "parentID": "spine:root", "title": "第一章", "isEnabled": true, "isCurrent": false }
      ],
      "selectedItemIDs": ["toc:0"],
      "allowedActions": ["activate"],
      "revision": 0
    }
  ]
}
```

**`performCommand`**

- `ui.navigator.action`（`contractVersion == 1`）：
  - 消息形态为 `{ "commandID": "ui.navigator.action", "contractVersion": 1, "action": { "contributionID": "ebook.toc", "kind": "activate", "itemIDs": ["toc:0.1"] }, "session": <完整 ContentSession> }`，其中尖括号仅表示嵌入对象，不是 JSON 字符串。
  - 只接受 `activate`，要求单个、真实存在且启用的 itemID，contributionID 必须为 `ebook.toc`；拒绝携带 move 的 destination/position。校验 session UUID、extensionID/providerID 与 runtime 内记录一致。由内部目录解析目标，不读取宿主快照中提供的 URL 或路径。
  - 按内部记录生成新快照，不在宿主传回的陈旧 session 上打补丁。渲染目标章节 → 原子写入文件 → URL 附加目标 fragment → 更新唯一选中项、`isCurrent`、`revision` → 编码并检查大小 → 提交内部记录并返回同一 UUID。
  - 同章不同 fragment 也更新完整 URL 与 revision；无 fragment 表示章首。重复激活相同目录项可返回当前快照，不要求重新滚回顶部。
  - 合法目标的渲染／写盘失败返回同 UUID 的 `.unavailable` 快照，保留可用目录并标记所选目标，让用户能换到其它章节重试；不得发布未写完或不存在的 document URL。非法消息返回 `1` 且不改变记录。
- `session.lifecycle`：
  - 消息结构对齐 kit 的 `SessionLifecycleRequest` 和 hifi 的 `SessionLifecycleMessage`：`operation`、完整 `session`，restore 还必须有对象 `restoration`（无媒体恢复值时为 `{}`）；拒绝空 itemID、非有限／负 position，close 不接受 restoration。
  - `close`：删除本会话目录、结束安全范围访问并移除记录；返回同 UUID 的 `.unavailable(titleKey: "EBook", messageKey: "EBook Session Closed")`，清空 navigator，保留 lifecycle capability 供重复关闭校验。EPUB 没有通用 stopped 字段，也不添加 mediaPlayback 来表示关闭。重复关闭幂等，只根据内部拥有记录清理文件，禁止用输入 presentation URL 推导删除路径。
  - `restore`：要求传入 UUID 对应活会话，返回该会话当前快照，不重建目录、不再调用 create、不更换 UUID。忽略合法但不适用的媒体恢复值；宿主此前已从原 request 创建并渲染首章。未知 UUID 返回 `1`；已失败的创建快照也可 no-op restore。
  - 未知操作/版本返回 `1`（invalidMessage）。
- 其它命令返回 `1`。
- 所有成功响应必须是 kit 可解码并通过现有 validator 的完整 `ContentSession`。C ABI 的 function table、struct size、输出内存分配和 `release_bytes` 生命周期按现有头文件与 hifi 实现，不修改共享 ABI，不暴露 Swift 对象。

**文件与清理**

- 使用 `FileManager.default.temporaryDirectory/foofoil-ebook/<runtime-uuid>/<session-uuid>/`，目录名由扩展生成，章节文件按需生成、原子写入并缓存；文件写成后保持不可变。runtime 隔离避免一个窗口或运行时清理另一个的文件。
- `close`/`destroy` 清理自身记录和 runtime 根目录；初始化不按“超过 24 小时”删除可能仍被活实例使用的目录。残留回收用 runtime 根下的系统 advisory lock：活 runtime 全程持锁，只清理最后修改超过 24 小时且能非阻塞独占加锁的旧根目录；遇到 symlink、非法目录名或锁失败直接跳过。Darwin 是系统依赖，可用于文件锁。退出／崩溃后由 OS 释放锁。
- close 清理失败必须记录诊断；尝试继续释放其它资源，并把仅包含自有路径的待清理记录留给 destroy／下次启动回收，不把失败视为可再次阅读的活会话。smoke 验证正常关闭立即删除且 destroy 兜底有效。
- 章节 HTML 文件只含目标 HTML，图片/CSS 已内联为 data URI。
- 同一 runtime 的创建／命令／关闭采用宿主串行 ABI 调用约定；不启动脱离会话生命周期的后台渲染任务。多窗口维护独立 session 记录。

### 3.7 大小限制与失败语义

在 `EPUBLimits` 集中定义以下上限（MiB = 1,048,576 bytes），在分配内存或创建文件前检查，不能只依赖 ZIP 声明的大小：

| 对象 | v1 上限 | 超限处理 |
| --- | --- | --- |
| 输入 EPUB 文件 | 1 GiB | 创建错误会话 |
| ZIP entry 数 / 中央目录大小 | 50,000 / 32 MiB | 创建错误会话 |
| 单个 entry 实际解压输出 | 32 MiB | 元数据／正文报错；装饰资源可移除 |
| 单个 XML DOM 节点数 / 元素深度 | 100,000 / 128 | 解析前以安全 SAX 预检并终止，避免先构造巨型 DOM |
| 单章累计资源解压量 / 最终 HTML UTF-8 | 64 MiB / 32 MiB | 章节错误呈现，保留换章能力 |
| 已缓存 HTML 总量／会话 | 256 MiB | 新章会超过时返回限制错误；保留已有文件，不删除 WebView 可能仍读取的旧文件 |
| 全部 navigator 节点（含 spine 分组） / 树深 | 2,000 / 32 | spine 超限则创建错误；原始 TOC 超限则降级为完整 spine 目录 |
| navigator 单个标题 | 256 Unicode 字符 | 展示标题截断；映射 ID 和路径保留原值 |
| 原始 request 编码后的 UTF-8 | 128 KiB | 返回 `2`；不丢弃书签以求通过预算 |
| 扩展完整会话 JSON | 512 KiB | 原始 TOC 降级为 spine；仍超限则返回无目录的限制错误会话 |

512 KiB 是给宿主 JSON 重编码、stateReference 及后续字段留余量的扩展预算，不等于宿主 1 MiB 硬上限。测试必须把回包用 kit 解码后重新编码，并交给实际 `ExtensionStateStore` 验证不超限。错误快照保留预算内 request，不能递归返回同一个超限快照。

ZIP 解压以实际输出增量计数并提前停止；CRC、长度、引用循环和流结束均需验证。XML 预检同样禁止外部实体，限制文件大小后再扫描。边界测试使用可注入的小 limits，覆盖等于上限和超过上限，不在测试中分配数 GiB 数据。

### 3.8 调试与验证工具

- `ebook-inspect <file.epub> [--chapter <zero-based-index>]`：打印标题、作者、目录树、降级诊断和指定章节 HTML 大小，不输出安全书签或完整书籍正文。
- `ebook-runtime-smoke`：
  - `--self-test` 时在临时目录生成最小夹具 EPUB（含 stored 与 deflate 两类 entry）；
  - 经真实 C ABI 调用 `createSession`，用 kit 解码完整会话并执行 navigator 校验，断言 providerID、presentation kind、两个层级的必填字段；
  - 从 kit 编码 `NavigatorActionRequest` 发送跨章及同章不同 fragment 的 activate，断言 URL／fragment、唯一选中项、revision 和 UUID；
  - 发送双资源请求，断言返回 `2`；
  - 发送 `session.lifecycle` close，断言临时目录被删除。
  - 经 kit 编码空 restoration 的 restore，断言 UUID、URL、活会话目录数量不变；close 两次都返回可解码快照；close 后 activate/restore 不得复活。
  - 打开两个会话，关闭一个不影响另一个；不 close 直接 destroy 也释放全部自有目录和访问。
  - 覆盖非法版本、未知 contribution/item/session、禁用条目、损坏 EPUB 和大小超限，失败后状态不被部分修改。

### 3.9 测试

`Tests/EBookExtensionCoreTests/`：

- ZIP：stored / raw deflate / data descriptor / 小型 ZIP64、CRC 错误、截断、越界 offset、路径穿越、重名、加密标志和资源上限。
- Container/OPF：EPUB3 nav、EPUB2 NCX、不同 namespace 前缀、层级、百分号路径及 fragment、无目录／不完整目录、linear=no、spine 完整可达性。
- Encryption：无 encryption.xml；仅字体混淆继续阅读并省略字体；正文加密／未知算法明确错误。
- Renderer：脚本和事件属性、外部实体、iframe/base/form/meta refresh、CSS @import / 转义 url、img/srcset/SVG、资源路径基准、引用循环、实体、同文件锚点保留、跨文件链接中性化、未知实体失败后仍可换章。
- Document：按需渲染、缓存预算、原始目录超限降级、会话关闭／恢复／多窗口清理。所有边界失败使用稳定错误 key。
- 夹具 EPUB 由测试内 ZIP 生成器构造，同时保留一个系统 ZIP 工具生成的独立 deflate 夹具（记录生成命令和预期内容），避免编码器和解码器共享错误而自测通过。夹具正文自行编写，可按 MIT 分发。

验证：

```sh
cd ebook
swift test
swift run ebook-runtime-smoke --self-test
```

## 4. foofoil 宿主

### 4.1 文档视图

新增：`ExtensionSupport/Presentation/ExtensionDocumentView.swift`

- `NSViewRepresentable` 包装专用 `WKWebView`，不复用浏览网页模式中的登录、导航或打开外部浏览器行为。Coordinator 持有加载状态、当前完整目标 URL、session UUID 和导航 generation。
- 按第 2.1 节验证 URL，去 fragment 后取得真实文件路径进行属性检查：必须是 `file:`、无远端 host，文件存在且为普通 HTML、非符号链接，且位于本体进程 `FileManager.default.temporaryDirectory` 之下（in-process 扩展写的就是这里；契约没有传“扩展私有根”，宿主只能按该前缀收紧）。宿主不得为了加载失败扩大 read access；自包含文件使用 `loadFileURL(targetURL, allowingReadAccessTo: fileURLWithoutFragment)`。
- 创建配置时设 `defaultWebpagePreferences.allowsContentJavaScript = false`、`websiteDataStore = .nonPersistent()`，不添加 JS bridge 或 user script。
- 首次加载前异步编译／缓存并安装 `WKContentRuleList`，采取默认拒绝：阻断网络 scheme，再仅放行 `file:` document 与 `data:` image/font。**待验证项**：WebKit 内容规则对 `file:`／`data:` 的匹配语义有限制，`url-filter: ".*"` + block 是否影响主文档、白名单是否按预期生效，必须在目标系统实测；“禁止网络”以本视图的 `allowsContentJavaScript = false` 与文档 CSP 为主，规则列表仅作纵深防御，不作为唯一保证。文件 document 的实际访问由下述 delegate 和单文件 read access 收紧；其它 file 子资源、网络 scheme 和其它 data 类型保持阻断。规则编译／安装失败显示 `Document Security Setup Failed`，不能先加载或降级成无规则 WebView。
- `WKNavigationDelegate` 只允许宿主当前请求的主文档文件与该文件的 fragment 导航；拒绝不同路径、远端 URL、子 frame、重定向到非目标及下载。`WKUIDelegate` 拒绝新窗口，任何被阻止链接不交给 `NSWorkspace.open`。响应阶段确认仍是目标 HTML，禁止触发下载回退。不能只用 navigation delegate 拦截图片／CSS 网络请求。
- 以完整 URL（包含 fragment）判断更新；同文件 fragment 改变时也执行带 fragment 的 `loadFileURL`。**待验证项**：`loadFileURL` 是否按 fragment 原生滚动到锚点需用真实 WebView 实测（含足够滚动距离并断言位置）；不可用时 v1 回退到章首，不启用 JS。缺失锚点落在章首。
- 用户正文内 fragment 点击由 WebKit 原生处理；SwiftUI 无关更新不重复加载。来自目录的目标变化取消上一导航并推进 generation，旧完成／失败回调不得覆盖新状态。session UUID 变化时更换视图身份，不沿用另一会话滚动位置。
- 加载中显示本地化进度；无效 URL、缺失文件、加载失败及 WebContent 进程终止显示明确占位。视图 teardown 调用 `stopLoading`、清空 delegate 并失效 generation；临时文件仅由 runtime 清理。关闭窗口与会话替换仍走宿主既有生命周期，异步关闭时忽略旧视图回调。
- 背景透明／跟随文档 CSS，保持现有边框与全屏外观；验证文字选择、滚动、焦点、键盘、目录面板展开以及窗口拖动不冲突。宿主不从 EPUB 私有 ID 分支判断呈现行为。

### 4.2 呈现路由

修改：`ExtensionSupport/Presentation/ExtensionPresentationView.swift`

- 音频 chrome 路径不变；
- 在通用文本呈现之前处理 `.document(url:)`，全幅渲染、不套用文本 16pt padding；
- `switch` 补齐 `.document` 分支（编译器强制穷尽）。

### 4.3 目录动作的异步顺序

修改：`foofoil/AppState/AppState+ContentOpen.swift` 的 `performNavigatorAction`，必要的 task／generation 状态放在既有 `AppState`。

- 当前代码仅在回包后检查 session UUID；runtime 的 ABI 锁只保证互斥，不保证多个 detached task 按用户点击顺序获得锁。
- 在每个 AppState 内使用一个串行 FIFO，最多一个 navigator ABI 调用在途；真正执行前读取当前 session 快照并检查 session UUID／route generation。新会话不得继承旧会话排队动作。
- 每项成功后再次检查 session UUID／route generation，按提交顺序更新 UI 和持久化，再取下一项；失败记录诊断并继续队列。后一项一定基于前一项更新后的快照，最后一次成功点击决定最终结果。v1 不合并、不丢弃连续点击，避免引入与其它 navigator 动作不同的时序语义。
- close／会话替换后丢弃待执行动作，并让既有 close 流程释放 runtime 记录；已经进入 ABI 的操作不能靠取消 Swift Task 假定中止。跨窗口仍由 runtime 锁串行，不新增全局 UI 状态。
- 对 generic navigator 实现，不写 `ebook.epub` 特例；保留既有内建目录路径和 Hi-Fi activate/move/remove 行为。所有扩展 navigator 动作均按提交顺序处理，为这些行为补回归测试。

### 4.4 本地化

修改：`Localizable.xcstrings`

- 补齐以下 key 的英文和 zh-Hans 翻译；已存在的 key 复用，不重复创建：

| Key | English | 简体中文 |
| --- | --- | --- |
| Table of Contents | Table of Contents | 目录 |
| EBook | EBook | 电子书 |
| EBook Invalid EPUB | This EPUB file is invalid or damaged. | 此 EPUB 文件无效或已损坏。 |
| EBook Unsupported Content | This EPUB contains unsupported content. | 此 EPUB 包含不支持的内容。 |
| EBook Encrypted Unsupported | This EPUB uses unsupported encryption. | 此 EPUB 使用了不支持的加密方式。 |
| EBook Limit Exceeded | This book or chapter exceeds the reading limits. | 此书籍或章节超出阅读限制。 |
| EBook Chapter Failed | This chapter could not be rendered. Choose another chapter. | 无法呈现此章节，请选择其他章节。 |
| EBook File Access Failed | The EPUB file could not be accessed. | 无法访问 EPUB 文件。 |
| EBook Session Closed | This book is closed. | 此书籍已关闭。 |
| Document Loading | Loading document… | 正在加载文档… |
| Document Load Failed | The document could not be loaded. | 无法加载文档。 |
| Document Security Setup Failed | Secure document loading could not be initialized. | 无法初始化安全文档加载。 |

- Runtime 的固定 navigator 分组标题“全部章节 / All Chapters”在 Runtime 代码内内置 en / zh-Hans 字符串表，按 `Locale.preferredLanguages` 选择，中文使用简体，其余回退英文；**不要依赖 SwiftPM resource bundle**，因为 `build-plugin` 目前只拷贝 dylib，`Bundle.module` 在 `.foofoilextension` 内不可靠；也不扩展 NavigatorItem 公共契约。若不希望在扩展内维护文案，可退而使用固定 key 交给宿主 `Localizable.xcstrings`（需新增同名条目）。诊断日志可记录解析原因，用户提示使用上述稳定 key，不拼接未本地化错误文本。

### 4.5 调试注入

修改：`foofoil/run`

- 把插件注入重构为 `hifi` / `ebook` 循环；两处 `build-plugin` 存在时分别构建；
- 维护本次成功构建的 bundle 白名单（`Hi-Fi.foofoilextension` / `EBook.foofoilextension`），逐个替换复制到 app 的 `Contents/PlugIns/`；不 glob 复制历史输出。对这两个受管理的开发 bundle，源脚本缺失时清理 app 中对应旧副本，防止“已跳过”但仍加载旧插件；不删除其它插件。
- 全部插件注入后只重签一次 app，并 `lsregister` 刷新；
- 缺失插件时打印跳过；脚本存在但构建失败时停止启动，不静默使用旧插件。清理或复制造成 app 内容变化后统一重签一次并刷新登记。沿用现有签名身份探测，不修改 entitlements。

### 4.6 工作区

修改：`foofoil.xcworkspace/contents.xcworkspacedata`

- 追加 `../ebook` FileRef，便于三仓库联编调试。

### 4.7 测试与打开入口

- `foofoilTests` 新增完整 document 会话解码、navigator validator、JSON 重编码后 `ExtensionStateStore` 保存／加载用例。
- WebView 策略测试：非法 scheme、远端 file host、缺失／symlink 文件、不同本地文件跳转、新窗口、规则初始化失败、旧导航回调、视图销毁。
- 使用本地 HTTP 请求计数器＋真实 WKWebView 夹具，涵盖 img/srcset、CSS @import/url、iframe、meta refresh、表单和脚本；分别测试 renderer 输出及刻意未清理的 document HTML，整个加载和交互期间请求数必须为零。data 图片／字体与 fragment 仍可用。不得只靠匹配清理后的字符串证明禁止网络。
- 使用 fake provider 控制异步返回顺序，覆盖连续 activate 最后点击生效、activate 与 move/remove 排队、切书期间旧回包隔离；回归 Hi-Fi navigator。
- 测试 `open → restore({}) → close`：只产生一个新的活会话，保存的旧 HTML 缺失也能从 EPUB 重新生成；失败会话重启后能重新尝试访问原书。
- 从应用“打开文件”、拖入现有窗口和历史恢复进入 `.epub`，确认 generic provider 匹配和单文件替换路径。Finder 双击系统关联不属于 v1 验收，不改宿主文件关联或最低系统版本。

## 5. 实施顺序

1. extension-kit：`document` 手写 Codable、完整会话 fixture、契约文档与测试；此步完成后确定唯一 JSON 形态。
2. foofoil：先用 fixture 做最小 WKWebView 路径，验证禁止网络、data 资源、同章 fragment 和单文件 read access；这些行为通过前不开始完整 EPUB 渲染器联调。
3. ebook：Core（ZIP／OPF／目录／资源清理／限制）与独立夹具测试；所有 spine 正文可达、字体混淆降级和失败语义通过。
4. ebook：Runtime、真实 ABI＋kit smoke、manifest、bundle 和 build-plugin；restore UUID、回包预算、多会话清理通过。
5. foofoil：完整呈现路由、navigator 顺序保证、本地化、run 注入、工作区、集成测试；回归 Hi-Fi 和内建目录。
6. 运行下面的全套验证并执行 `./run`；完成所有手动项后交付。记录未通过项，不能以“只通过 Codable 测试”宣称功能完成。

分期建议，避免一次性铺满生产级加固：**P0** 为第 1–5 步的核心阅读链路——`document` 契约、宿主最小 WKWebView（`allowsContentJavaScript = false` + CSP + 导航白名单 + 单文件 read access）、renderer 清理/内联、navigator（含禁用分组或第二个 contribution）、单文件约束、close/restore/清理；**P1** 为内容规则列表、XML SAX 预检、第 3.7 节极限矩阵的完整组合、全量网络计数测试。navigator 动作 FIFO 属于正确性要求，保留在 P0。第 4.1 节的“待验证项”必须在 P0 完成前给出实测结论。

## 6. 验证清单

```sh
# 从包含 extension-kit / ebook / foofoil 的父目录开始
# 1. 契约
cd extension-kit && swift test

# 2. 扩展
cd ../ebook && swift test && swift run ebook-runtime-smoke --self-test

# 3. 宿主
cd ../foofoil && xcodebuild test -project foofoil.xcodeproj -scheme foofoil -destination 'platform=macOS'

# 4. 运行与手动验证
./run
```

手动验证项：

- 打开真实 `.epub`：正文富文本渲染、侧边树形目录出现；
- EPUB2 NCX 和 EPUB3 nav 各至少一本；目录完整、不完整和无目录夹具均能访问所有 spine 项；
- 点击目录项：跨章切换、同章不同 fragment 精确定位且唯一选中态更新；缺失锚点回到章首；
- 快速连续点击三项，最终正文／选中态／持久化一致地对应最后一项；换书期间没有旧内容回闪；
- 同箔打开第二个 EPUB：旧会话关闭并替换；
- 两个窗口分别读两本书，关闭一个不影响另一个；正常关闭后该会话临时目录被清理；
- 重启应用／从历史恢复时从原 EPUB 重建首章，原 HTML 即使已删除也能阅读，不泄漏第二个会话；
- 字体混淆书仍能阅读；正文加密、超限、损坏章、无权限文件显示对应提示。结构解析成功但某章渲染失败时，仍允许通过目录访问其它可渲染章节；
- 网络夹具实际请求数为零，data 图片仍显示，点击外链不会打开浏览器；
- 深色／浅色、全屏、缩放、滚动、文字选择、键盘焦点及禁用分组父节点展开正常；
- `./run` 同时注入两插件，既有 Hi-Fi 列表操作及内建目录不回归；切走 EPUB 后也释放文件访问。

## 7. 限制与非目标（v1）

- 不支持 DRM／正文加密或未知加密算法；已识别的仅字体混淆降级为系统字体；
- 不支持跨章节超链接跳转（同章节 fragment 可跳）；
- 不支持恢复上次阅读章节（宿主恢复契约只覆盖媒体队列与进度）；
- 不做固定版式（fixed-layout）优化，manga 类仅按图片最大宽度缩放；
- 不做全文搜索、批注、阅读书签；已有宿主目录搜索继续复用；
- 不支持脚本、音视频、表单、跨文件 CSS @import、未知 HTML 实体或非 XHTML spine 正文；资源与书籍大小受第 3.7 节限制；
- 仅本地资源，禁止网络加载；章节按文件生成，不进入会话 JSON。

## 8. 风险与缓解

- **WKWebView 大章节卡顿**：后台按章生成、解压／DOM／HTML／缓存均有硬限制；不把“按章”当作无限资源保证。
- **会话持久化超限**：正文落文件，目录仍占 JSON；用 512 KiB 完整快照预算、spine 降级及宿主重编码持久化测试保证边界。
- **XHTML 实体/解析失败**：安全实体预处理、统一禁用外部实体；返回稳定 `.unavailable` 错误并保留目录，不回退加载未清理原文。
- **沙盒文件访问**：书签解析 + 会话期持有；宿主也保留对原文件的安全范围访问兜底。
- **HTML 安全**：扩展清理＋CSP，宿主在首次加载前安装默认拒绝规则、导航白名单及单文件 read access，以真实 WebView 请求计数测试验收。
- **生命周期与异步回包**：restore 不重建、关闭幂等、runtime 根持锁、宿主按动作顺序更新且隔离旧会话回包；测试替换、重启和多窗口。

## 9. 实施依据

- 项目实际契约：`extension-kit/Sources/FoofoilExtensionKit/ContentSession.swift`、`NavigatorContribution.swift`、`NavigatorActionRequest.swift`、`SessionLifecycle.swift`。
- 宿主实际行为：`foofoil/foofoil/ExtensionSupport/Runtime/ExtensionLoader.swift`、`InProcessContentProvider.swift`、`ExtensionSessionLifecycle.swift`、`ExtensionStateStore.swift`，以及 `foofoil/foofoil/AppState/AppState+ContentOpen.swift`。
- [Apple COMPRESSION_ZLIB](https://developer.apple.com/documentation/compression/compression_zlib)：Compression 的输出为 raw DEFLATE；仍须自行校验 ZIP 元数据与 CRC。
- [Apple WKContentRuleList](https://developer.apple.com/documentation/webkit/wkcontentrulelist) 与 [JavaScript 开关](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript)：资源规则与脚本开关分别实施。
- [W3C EPUB 3.3](https://www.w3.org/TR/epub-33/)：用于核对 container、spine、导航及字体混淆；`encryption.xml` 存在不等于 DRM。
