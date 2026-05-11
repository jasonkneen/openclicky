// ThreeDViewerView.swift
// SwiftUI inline 3D viewer for generated GLB assets.
//
// Loads via GLTFSceneKit (https://github.com/magicien/GLTFSceneKit) which must
// be added as a Swift Package dependency to the leanring-buddy target.
// Falls back to a graceful error placeholder if the GLB can't be loaded.

import SwiftUI
import SceneKit

#if canImport(GLTFSceneKit)
import GLTFSceneKit
#endif

struct ThreeDViewerView: View {

    let glbURL: URL
    var autoRotate: Bool = true
    var background: Color = Color(nsColor: .underPageBackgroundColor)
    var allowsCameraControl: Bool = true

    @State private var loadError: String?
    @State private var scene: SCNScene?

    init(
        glbURL: URL,
        autoRotate: Bool = true,
        background: Color = Color(nsColor: .underPageBackgroundColor),
        allowsCameraControl: Bool = true
    ) {
        self.glbURL = glbURL
        self.autoRotate = autoRotate
        self.background = background
        self.allowsCameraControl = allowsCameraControl
    }

    var body: some View {
        ZStack {
            background

            if let scene {
                SceneView(
                    scene: scene,
                    options: optionsForViewer
                )
                .accessibilityLabel("3D model viewer")
            } else if let error = loadError {
                VStack(spacing: 6) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Couldn't open 3D model")
                        .font(.callout)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .padding()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: glbURL) {
            await load()
        }
    }

    private var optionsForViewer: SceneView.Options {
        var opts: SceneView.Options = []
        if allowsCameraControl { opts.insert(.allowsCameraControl) }
        if autoRotate { opts.insert(.autoenablesDefaultLighting) }
        return opts
    }

    private func load() async {
        scene = nil
        loadError = nil

        let url = glbURL
        let result: Result<SCNScene, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let loaded = try Self.loadScene(from: url)
                return .success(loaded)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let s):
            tuneSceneForChatBubble(s)
            self.scene = s
        case .failure(let e):
            self.loadError = e.localizedDescription
        }
    }

    private func tuneSceneForChatBubble(_ scene: SCNScene) {
        // Soft fill light to keep low-poly flats readable.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 250
        ambient.light?.color = NSColor(white: 1.0, alpha: 1.0)
        scene.rootNode.addChildNode(ambient)

        // Auto-rotate root content (skip cameras / lights).
        if autoRotate {
            let rotate = SCNAction.repeatForever(
                SCNAction.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 12)
            )
            for child in scene.rootNode.childNodes {
                let isLightOrCam = child.light != nil || child.camera != nil
                if !isLightOrCam { child.runAction(rotate) }
            }
        }
    }

    // MARK: - GLB → SCNScene

    private static func loadScene(from url: URL) throws -> SCNScene {
        #if canImport(GLTFSceneKit)
        let source = try GLTFSceneSource(url: url)
        return try source.scene()
        #else
        // Fallback: SceneKit can natively load .scn / .usdz only.
        // If GLTFSceneKit isn't linked, attempt to load via SCNScene anyway so
        // .usdz fallbacks still work, otherwise throw.
        do {
            let s = try SCNScene(url: url, options: nil)
            return s
        } catch {
            throw NSError(
                domain: "ThreeDViewerView",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "GLTFSceneKit package is not linked. Add https://github.com/magicien/GLTFSceneKit as a Swift Package dependency."]
            )
        }
        #endif
    }
}
