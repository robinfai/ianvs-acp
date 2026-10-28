# ianvs_mermaid

Optional Flutter native Mermaid rendering, extracted from the chat package.
Import `package:ianvs_mermaid/ianvs_mermaid.dart` and inject `MermaidView` through
`ChatMessageBody.diagramBuilder` or `ChatRenderingScope.diagramBuilder`.
The core and base chat package do not depend on this package or `merman`.

The native renderer owns its engine/cache; hosts own any renderer they inject.
Merman 0.7.0 macOS integration uses CocoaPods, requires macOS 12+, and needs the
existing host dylib normalization/signing phase. The app in this workspace is the
reference integration. This package does not claim mobile native support.

Run `flutter pub get`, `flutter analyze`, and `flutter test` here.
