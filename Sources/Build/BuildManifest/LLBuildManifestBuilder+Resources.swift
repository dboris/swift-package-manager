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

import struct LLBuildManifest.Node
import struct Basics.AbsolutePath
import struct Basics.RelativePath

import PackageModel
import SPMBuildCore

extension LLBuildManifestBuilder {
    /// Adds command for creating the resources bundle of the given target.
    ///
    /// Returns the virtual node that will build the entire bundle.
    func createResourcesBundle(
        for target: ModuleBuildDescription
    ) throws -> Node? {
        guard let bundlePath = target.bundlePath else { return nil }

        var outputs: [Node] = []

        let infoPlistDestination = try RelativePath(validating: "Info.plist")

        // WinCatalyst identity (fluentui-apple port, slice 4): under the
        // wincatalyst-*-ios SDKs (platformOverride == .iOS, the same opt-in signal
        // Half B keys on), an `.xcassets` catalog is compiled at build time by
        // `wincatalyst-assetc` -- our replacement for Apple's actool -- into
        // flattened PNGs + a `wincatalyst-assets.plist` manifest at the bundle
        // resource root (read by UIImage(named:in:), Frameworks/UIKit/UIImage.mm),
        // instead of copying the raw catalog (which the runtime cannot read).
        let winCatIdentity = target.buildParameters.platformOverride == .iOS

        // Create a copy (or, for .xcassets under identity, an assetc) command for
        // each resource file.
        for resource in target.resources {
            switch resource.rule {
            case .copy, .process:
                if winCatIdentity, resource.path.extension == "xcassets" {
                    let output = try addWinCatalystAssetCatalogCommand(
                        catalog: resource.path,
                        bundlePath: bundlePath,
                        target: target
                    )
                    outputs.append(output)
                    continue
                }
                let destination = try bundlePath.appending(resource.destination)
                let (_, output) = addCopyCommand(from: resource.path, to: destination)
                outputs.append(output)
            case .embedInCode:
                break
            }
        }

        // Create a copy command for the Info.plist if a resource with the same name doesn't exist yet.
        if let infoPlistPath = target.resourceBundleInfoPlistPath {
            let destination = bundlePath.appending(infoPlistDestination)
            let (_, output) = addCopyCommand(from: infoPlistPath, to: destination)
            outputs.append(output)
        }

        let cmdName = target.llbuildResourcesCmdName
        self.manifest.addPhonyCmd(name: cmdName, inputs: outputs, outputs: [.virtual(cmdName)])

        return .virtual(cmdName)
    }

    /// WinCatalyst identity (fluentui-apple port, slice 4): emit a shell command
    /// running `wincatalyst-assetc <catalog> <bundlePath>`, which flattens the
    /// `.xcassets` into PNGs + `wincatalyst-assets.plist` at the bundle resource
    /// root. Returns the manifest-plist output node (the deterministic primary
    /// output llbuild sequences the bundle phony on; the PNGs are side outputs).
    /// The tool ships next to the SDK's swiftc (`<toolchain>/bin/`), staged by
    /// cmake/sdk-install*.cmake.
    private func addWinCatalystAssetCatalogCommand(
        catalog: AbsolutePath,
        bundlePath: AbsolutePath,
        target: ModuleBuildDescription
    ) throws -> Node {
        // Host exe suffix from swiftc (swiftc.exe on Windows, swiftc elsewhere) so
        // the tool name is host-correct.
        let toolName = target.buildParameters.toolchain.swiftCompilerPath.extension == "exe"
            ? "wincatalyst-assetc.exe" : "wincatalyst-assetc"
        // Resolve assetc relative to the target Swift SDK toolset's rootPaths (i.e.
        // `<Sdk>/toolchain/bin`). This is SWIFT_EXEC-immune: swiftCompilerPath moves
        // to the STOCK swiftc when the gate sets SWIFT_EXEC for the host manifest
        // compile, but the toolset root still points at the SDK's own toolchain.
        // assetc ships in a DEDICATED `<toolchain>/assetc/` dir (a sibling of bin),
        // self-contained with its interop foundation.dll closure -- it CANNOT live
        // in toolchain/bin, whose stock swift `Foundation.dll` overlay collides
        // (case-insensitively) with our `foundation.dll` (sdk-install*.cmake).
        let rootPaths = target.buildParameters.toolchain.swiftSDK.toolset.rootPaths
        let candidates = rootPaths.flatMap { root in [
            root.parentDirectory.appending(components: "assetc", toolName), // <toolchain>/assetc/
            root.appending(component: toolName),                            // <toolchain>/bin/ (fallback)
        ] }
        let assetc = candidates.first(where: { self.fileSystem.exists($0) })
            ?? candidates.first
            ?? target.buildParameters.toolchain.swiftCompilerPath.parentDirectory.appending(component: toolName)

        let input = Node.directory(catalog)
        let manifestOut = bundlePath.appending(component: "wincatalyst-assets.plist")
        let output = Node.file(manifestOut)

        self.manifest.addShellCmd(
            name: manifestOut.pathString,
            description: "Compiling asset catalog \(catalog.basename) (wincatalyst-assetc)",
            inputs: [input],
            outputs: [output],
            arguments: [assetc.pathString, catalog.pathString, bundlePath.pathString]
        )
        return output
    }
}
