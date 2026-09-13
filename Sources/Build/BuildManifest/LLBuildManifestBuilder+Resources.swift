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

import PackageGraph
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

        // Create a copy command for each resource file -- unless WinCatalyst's
        // resource-compiler table claims it (an `.xcassets`, `.storyboard` or `.xib`
        // the target Swift SDK ships a compiler for), in which case it is COMPILED
        // into the bundle rather than copied. A copied catalog or storyboard is one
        // the runtime cannot read.
        for resource in target.resources {
            switch resource.rule {
            case .copy, .process:
                if let output = try addWinCatalystCompiledResourceCommand(
                    resource: resource.path,
                    bundlePath: bundlePath,
                    target: target
                ) {
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

    /// WinCatalyst resource pipeline: if this resource is one of the file types a
    /// WinCatalyst SDK can COMPILE, emit the shell command that compiles it into the
    /// bundle and return its primary output node; otherwise return nil and let the
    /// caller copy the file through.
    ///
    /// The table, and the on-disk shape each entry produces:
    ///
    ///   `.xcassets`   `wincatalyst-assetc <catalog> <bundleDir>`
    ///                 -> flattened PNGs + `wincatalyst-assets.plist` at the bundle
    ///                    resource root (read by UIImage(named:in:), UIImage.mm).
    ///   `.storyboard` `xib2nib <in> <bundleDir>/<name>.storyboardc`
    ///                 -> a DIRECTORY of per-scene nibs + an Info.plist scene map,
    ///                    which is what -[UIStoryboard storyboardWithName:bundle:]
    ///                    reads (UIStoryboard.mm).
    ///   `.xib`        `xib2nib <in> <bundleDir>/<name>.nib`
    ///                 -> a single binary NIBArchive (UINib.mm).
    ///
    /// Each entry declares ONE deterministic primary output for llbuild to sequence
    /// the bundle phony on; everything else the tool writes is a side output. For the
    /// two directory-producing entries that primary output is a FILE INSIDE the
    /// directory (the manifest plist / the scene map) rather than a directory node.
    ///
    /// NOT gated on the `-ios` identity: it is keyed on the target SDK shipping the
    /// tool, so an app compiles its resources under `-windows` too. See
    /// SPMBuildCore/WinCatalystResourceTools.swift for why the capability is a
    /// shipped artifact rather than a flag.
    private func addWinCatalystCompiledResourceCommand(
        resource: AbsolutePath,
        bundlePath: AbsolutePath,
        target: ModuleBuildDescription
    ) throws -> Node? {
        let tool: WinCatalystResourceTool
        let input: Node
        /// The path handed to the tool as its output argument.
        let outputArgument: AbsolutePath
        /// The deterministic file the tool always writes, used as the llbuild output.
        let primaryOutput: AbsolutePath
        let description: String

        switch resource.extension {
        case "xcassets":
            tool = .assetCatalog
            input = .directory(resource)
            outputArgument = bundlePath
            primaryOutput = bundlePath.appending(component: "wincatalyst-assets.plist")
            description = "Compiling asset catalog \(resource.basename) (wincatalyst-assetc)"
        case "storyboard":
            tool = .interfaceBuilder
            input = .file(resource)
            let compiledDirectory = bundlePath.appending(
                component: "\(resource.basenameWithoutExt).storyboardc"
            )
            outputArgument = compiledDirectory
            primaryOutput = compiledDirectory.appending(component: "Info.plist")
            description = "Compiling storyboard \(resource.basename) (xib2nib)"
        case "xib":
            tool = .interfaceBuilder
            input = .file(resource)
            outputArgument = bundlePath.appending(component: "\(resource.basenameWithoutExt).nib")
            primaryOutput = outputArgument
            description = "Compiling \(resource.basename) (xib2nib)"
        default:
            // Includes an already-compiled `.nib`, which FileRuleDescription.xib also
            // matches: it is copied through, not re-compiled.
            return nil
        }

        // Host exe suffix from swiftc (swiftc.exe on Windows, swiftc elsewhere).
        let exeSuffix = target.buildParameters.toolchain.swiftCompilerPath.extension == "exe"
            ? "exe" : ""
        guard let toolPath = target.buildParameters.toolchain.swiftSDK.winCatalystResourceToolPath(
            tool,
            exeSuffix: exeSuffix,
            fileSystem: self.fileSystem
        ) else {
            // The SDK classified this file as a processable resource (the rule set is
            // added when it ships ANY resource tool) but does not carry THIS one.
            // Fall back to copying, and say so -- a silently copied catalog or
            // storyboard is unreadable at runtime and would otherwise look fine.
            self.observabilityScope.emit(
                warning: """
                    \(resource.basename) needs \(tool.executableStem), which this Swift SDK does not \
                    ship (expected in <toolchain>/\(tool.directoryName)/); copying the source file \
                    through instead -- the runtime cannot read it
                    """
            )
            return nil
        }

        let output = Node.file(primaryOutput)
        // xib2nib is told the TARGET'S MODULE NAME, the way ibtool learns it from the
        // build: Xcode's fresh storyboard says `customModuleProvider="target"` with NO
        // `customModule`, meaning "the class lives in the module of the target that
        // compiles me". Without this the compiled nib records the bare class name and
        // the runtime has to guess the module from the executable's name.
        var arguments = [toolPath.pathString]
        if tool == .interfaceBuilder {
            arguments += ["--module", target.module.c99name]
        }
        arguments += [resource.pathString, outputArgument.pathString]
        self.manifest.addShellCmd(
            name: primaryOutput.pathString,
            description: description,
            inputs: [input],
            outputs: [output],
            arguments: arguments
        )
        return output
    }
}
