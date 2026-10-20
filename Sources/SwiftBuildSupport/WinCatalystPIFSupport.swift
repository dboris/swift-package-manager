//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageModel
import SPMBuildCore

import enum SwiftBuild.ProjectModel

/// What the WinCatalyst fork needs while ONE PIF is written: the build's identity
/// override and the resource compilers its target Swift SDK ships. Both come from the
/// target `BuildParameters`, which the per-package builders never see, so `PIFBuilder`
/// binds this around the (synchronous) `PackagePIFBuilder.build()` calls.
struct WinCatalystPIFContext: Sendable {
    @TaskLocal static var current: WinCatalystPIFContext?

    var identity: WinCatalystPlatformIdentity?
    var resourceTools: [WinCatalystResourceTool: AbsolutePath]

    init(buildParameters: BuildParameters, fileSystem: FileSystem) {
        self.identity = WinCatalystPlatformIdentity(buildParameters: buildParameters)
        let toolchain = buildParameters.toolchain
        let exeSuffix = toolchain.swiftCompilerPath.extension == "exe" ? "exe" : ""
        var tools: [WinCatalystResourceTool: AbsolutePath] = [:]
        for tool in WinCatalystResourceTool.allCases {
            if let path = toolchain.swiftSDK.winCatalystResourceToolPath(tool, exeSuffix: exeSuffix, fileSystem: fileSystem) {
                tools[tool] = path
            }
        }
        self.resourceTools = tools
    }
}

/// WinCatalyst identity under Swift Build.
///
/// The native engine resolves `.when(platforms:)` in SwiftPM against
/// `BuildParameters.currentPlatform`, which `platformOverride` turns into iOS for a
/// `-wincatalyst-identity` Swift SDK. Swift Build never sees that: the PIF builder writes
/// every platform condition into the PIF as a platform filter or a
/// `KEY[__platform_filter=...]` setting, and Swift Build matches those against the
/// platform of the real triple (windows/linux/android). So the identity is applied
/// where the conditions are WRITTEN: iOS and the real platform swap names.
///
/// Swapping (rather than mapping iOS onto the real platform and dropping the real
/// platform's own conditions) is what keeps the native semantics exact:
/// - `.when(platforms: [.iOS])` -> a filter on the real platform: matches.
/// - `.when(platforms: [.windows])` on Windows -> a filter on iOS: never matches, as
///   in the native engine where the current platform is iOS. Dropping it instead would
///   leave an EMPTY filter set, which Swift Build reads as unconditional.
/// - every other platform is untouched (it never matched either way).
///
/// Scope: the swap covers the whole PIF of one `constructPIF`, so a HOST-built target
/// (a macro, a plugin tool) sees it too when host and target share an OS; the native
/// engine resolves those with the host parameters, which carry no override. A host
/// target conditioned on its own OS is the one place the two engines differ.
struct WinCatalystPlatformIdentity: Sendable {
    /// The platform conditions are evaluated AS (iOS).
    let identity: PackageModel.Platform
    /// The platform Swift Build evaluates them against (the triple's).
    let real: PackageModel.Platform

    /// nil when this build carries no identity override, or the override IS the triple's platform.
    init?(buildParameters: BuildParameters) {
        guard let identity = buildParameters.platformOverride else { return nil }
        let real = buildParameters.platformFromTriple
        guard identity.name != real.name else { return nil }
        self.identity = identity
        self.real = real
    }

    /// The platform name to WRITE into the PIF for a condition on `platform`.
    static func mapCondition(_ platform: PackageModel.Platform) -> PackageModel.Platform {
        guard let swap = WinCatalystPIFContext.current?.identity else { return platform }
        if platform.name == swap.identity.name { return swap.real }
        if platform.name == swap.real.name { return swap.identity }
        return platform
    }
}

/// WinCatalyst's resource compilers under Swift Build: the same table, command lines and
/// outputs as the native engine's (Build/BuildManifest/LLBuildManifestBuilder+Resources.swift),
/// emitted as PIF custom tasks on the resource-bundle target.
///
/// Swift Build's own compilers for these types (actool, ibtool, momc, mapc) are
/// darwin-domain specs, so off-Darwin it recognises the files, matches no rule, and
/// copies the SOURCE into the bundle -- a catalog or storyboard the runtime cannot read.
/// A custom task (an argv run directly, no shell, so it works on a Windows host)
/// compiles it instead, and the file is kept out of the resources and sources phases.
///
/// Outputs land at `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)` -- the bundle's
/// resource root, where the native engine put them at the `.resources` root.
struct WinCatalystCompiledResource {
    let tool: WinCatalystResourceTool
    let commandLine: [String]
    let inputs: [String]
    let primaryOutput: String
    let description: String

    /// nil when the resource is not a type WinCatalyst compiles (including an already
    /// compiled `.nib`), or the SDK does not ship the tool for it -- the caller then gives
    /// it Swift Build's default treatment (with a warning in the second case).
    static func make(
        resourcePath: AbsolutePath,
        moduleC99Name: String,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) -> WinCatalystCompiledResource? {
        guard let context = WinCatalystPIFContext.current, !context.resourceTools.isEmpty else { return nil }
        let resourceDir = "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)"
        let stem = resourcePath.basenameWithoutExt

        let tool: WinCatalystResourceTool
        let outputArgument: String
        let primaryOutput: String
        let description: String
        switch resourcePath.extension {
        case "xcassets":
            tool = .assetCatalog
            outputArgument = resourceDir
            primaryOutput = "\(resourceDir)/wincatalyst-assets.plist"
            description = "Compiling asset catalog \(resourcePath.basename) (wincatalyst-assetc)"
        case "storyboard":
            tool = .interfaceBuilder
            outputArgument = "\(resourceDir)/\(stem).storyboardc"
            primaryOutput = "\(outputArgument)/Info.plist"
            description = "Compiling storyboard \(resourcePath.basename) (xib2nib --module \(moduleC99Name))"
        case "xib":
            tool = .interfaceBuilder
            outputArgument = "\(resourceDir)/\(stem).nib"
            primaryOutput = outputArgument
            description = "Compiling \(resourcePath.basename) (xib2nib --module \(moduleC99Name))"
        case "xcdatamodeld":
            tool = .dataModel
            outputArgument = "\(resourceDir)/\(stem).momd"
            primaryOutput = "\(outputArgument)/VersionInfo.plist"
            description = "Compiling data model \(resourcePath.basename) (wincatalyst-momc)"
        case "xcdatamodel":
            tool = .dataModel
            outputArgument = "\(resourceDir)/\(stem).mom"
            primaryOutput = outputArgument
            description = "Compiling data model \(resourcePath.basename) (wincatalyst-momc)"
        case "xcmappingmodel":
            tool = .mappingModel
            outputArgument = "\(resourceDir)/\(stem).cdm"
            primaryOutput = outputArgument
            description = "Compiling mapping model \(resourcePath.basename) (wincatalyst-mapc)"
        default:
            return nil
        }

        guard let toolPath = context.resourceTools[tool] else {
            observabilityScope.emit(
                warning: """
                    \(resourcePath.basename) needs \(tool.executableStem), which this Swift SDK does not \
                    ship (expected in <toolchain>/\(tool.directoryName)/); copying the source file \
                    through instead -- the runtime cannot read it
                    """
            )
            return nil
        }

        // xib2nib is told the target's module, the way ibtool learns it from the build
        // (see the native rule for why).
        var commandLine = [toolPath.pathString]
        if tool == .interfaceBuilder {
            commandLine += ["--module", moduleC99Name]
        }
        commandLine += [resourcePath.pathString, outputArgument]

        // A catalog / model / mapping model is a DIRECTORY, and a custom task's inputs are
        // file nodes: list its files so an edit inside it reruns the task. (A file ADDED
        // inside it reruns only once the PIF is regenerated -- the native engine's
        // directory-tree node had no such gap.)
        var inputs = [toolPath.pathString, resourcePath.pathString]
        if fileSystem.isDirectory(resourcePath) {
            inputs += Self.files(under: resourcePath, fileSystem: fileSystem).map(\.pathString)
        }

        return WinCatalystCompiledResource(
            tool: tool,
            commandLine: commandLine,
            inputs: inputs,
            primaryOutput: primaryOutput,
            description: description
        )
    }

    var customTask: ProjectModel.CustomTask {
        ProjectModel.CustomTask(
            commandLine: self.commandLine,
            environment: [],
            workingDirectory: nil,
            executionDescription: self.description,
            inputFilePaths: self.inputs,
            outputFilePaths: [self.primaryOutput],
            enableSandboxing: false,
            preparesForIndexing: false
        )
    }

    private static func files(under directory: AbsolutePath, fileSystem: FileSystem) -> [AbsolutePath] {
        var result: [AbsolutePath] = []
        guard let entries = try? fileSystem.getDirectoryContents(directory) else { return result }
        for entry in entries.sorted() {
            let path = directory.appending(component: entry)
            if fileSystem.isDirectory(path) {
                result += Self.files(under: path, fileSystem: fileSystem)
            } else {
                result.append(path)
            }
        }
        return result
    }
}
