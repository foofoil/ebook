# EBook for foofoil

EPUB reading extension for [foofoil](https://github.com/foofoil/foofoil). Requires foofoil; it is not a standalone reader.

This repository owns EPUB container/package/navigation parsing, chapter HTML rendering, and the `foofoil_extension_create` runtime that speaks JSON value messages. The table of contents is projected through foofoil's shared navigator panel; there is no private sidebar or custom host view.

## Scope (v1)

- One EPUB per session: a window opens a single `.epub` and replaces the previous session.
- Sidebar TOC uses `ui.navigator` outline; clicking an entry switches chapters through `ui.navigator.action`.
- Chapters are rendered to self-contained local HTML (images/CSS inlined as data URIs) and presented by the host document view.
- Font obfuscation is degraded to system fonts; DRM/encrypted content is rejected with a clear message.

Not supported: DRM, cross-chapter links, last-read position restore, fixed-layout optimization, full-text search, annotations, and bookmarks.

## Build and Test

```sh
swift test
swift run ebook-runtime-smoke --self-test
swift run ebook-inspect /path/to/book.epub [--chapter 0]
```

The runtime does not depend on `extension-kit`; the local package dependency is used only by the smoke executable and contract validation. Build the plugin bundle with:

```sh
./build-plugin /tmp/foofoil-ebook-plugin
```

## Layout

- `Sources/EBookExtensionCore` — ZIP, OCF container, OPF package, EPUB3 nav / EPUB2 NCX, chapter renderer, size limits.
- `Sources/EBookExtensionRuntime` — `foofoil_extension_create`, JSON session protocol, navigator actions, session lifecycle and temp-file cleanup.
- `Sources/EBookInspect` — CLI diagnostics.
- `Sources/EBookRuntimeSmoke` — real-ABI smoke test.
- `Sources/EBookTestSupport` — shared fixture EPUB builder.
- `docs/ebook-extension-plan.zh-CN.md` — implementation plan and constraints.

## License

MIT License, copyright © 2026 Beijing Memory Vision Technology Co., Ltd.
