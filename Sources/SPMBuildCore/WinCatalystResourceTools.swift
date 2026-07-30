//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageModel

/// WinCatalyst's build-time resource compilers -- the off-Apple stand-ins for
/// `actool` and `ibtool`, shipped inside a WinCatalyst Swift SDK.
///
/// THE SIGNAL IS TOOL PRESENCE, NOT AN SDK IDENTITY. The `.xcassets` rule
/// originally keyed off `-wincatalyst-identity` (the `wincatalyst-*-ios` SDKs), but
/// that one flag also flips `#if os(iOS)` and the `.when(platforms:)` resolution,
/// which drags every dependency onto its Darwin arm. An APP has to be buildable
/// under the plain `-windows` identity and still get its catalogs and storyboards
/// compiled, so the two decisions are separated: identity stays a compiler
/// behaviour, and resource compilation is a property of the DESTINATION -- does
/// this Swift SDK ship the tools?
///
/// Presence is meaningful rather than incidental: win-catalyst's
/// `cmake/sdk-install.cmake` stages each tool into its own directory beside
/// `toolchain/bin` (they cannot live IN `bin`, whose stock swift `Foundation.dll`
/// collides case-insensitively with WinCatalyst's own `foundation.dll`), and the
/// harmony toolchain dist deliberately carries neither. Detecting the tool also
/// needs no new `toolset.json` key -- `knownTools` is keyed by a fixed enum, so an
/// unknown key would risk a decode failure in a STOCK swift-build pointed at the
/// same SDK.
///
/// See docs/handoffs/2026-07-29-swiftpm-resource-pipeline.md in win-catalyst.
public enum WinCatalystResourceTool: CaseIterable {
    /// `.xcassets` -> flattened PNGs + `wincatalyst-assets.plist` (our Assets.car).
    case assetCatalog
    /// `.xib`/`.storyboard` -> binary NIBArchive (a `.storyboardc` dir for a
    /// storyboard, a single `.nib` for a xib).
    case interfaceBuilder

    /// The dedicated directory the tool ships in, a sibling of `toolchain/bin`.
    public var directoryName: String {
        switch self {
        case .assetCatalog: return "assetc"
        case .interfaceBuilder: return "xib2nib"
        }
    }

    /// The executable stem (no host extension).
    public var executableStem: String {
        switch self {
        case .assetCatalog: return "wincatalyst-assetc"
        case .interfaceBuilder: return "xib2nib"
        }
    }
}

extension SwiftSDK {
    /// Resolve one of WinCatalyst's resource compilers inside this Swift SDK, or
    /// nil when this SDK does not ship it.
    ///
    /// Resolution walks the toolset's `rootPaths` (i.e. `<Sdk>/toolchain/bin`) and
    /// looks in the tool's own sibling directory first, then in the root itself as
    /// a fallback for a future layout. Deliberately NOT relative to
    /// `swiftCompilerPath`: a gate that sets `SWIFT_EXEC` moves that to the stock
    /// host swiftc, while the toolset root still points into the SDK.
    public func winCatalystResourceToolPath(
        _ tool: WinCatalystResourceTool,
        exeSuffix: String,
        fileSystem: FileSystem
    ) -> AbsolutePath? {
        let name = exeSuffix.isEmpty ? tool.executableStem : "\(tool.executableStem).\(exeSuffix)"
        for root in self.toolset.rootPaths {
            let candidates = [
                root.parentDirectory.appending(components: tool.directoryName, name),
                root.appending(component: name),
            ]
            if let found = candidates.first(where: { fileSystem.exists($0) }) {
                return found
            }
        }
        return nil
    }

    /// True when this Swift SDK ships ANY of the resource compilers -- the signal
    /// that its consumers' `.xcassets` / `.xib` / `.storyboard` should be classified
    /// as processable resources rather than dropped as unhandled files.
    public func carriesWinCatalystResourceTools(
        exeSuffix: String,
        fileSystem: FileSystem
    ) -> Bool {
        WinCatalystResourceTool.allCases.contains {
            self.winCatalystResourceToolPath($0, exeSuffix: exeSuffix, fileSystem: fileSystem) != nil
        }
    }
}
