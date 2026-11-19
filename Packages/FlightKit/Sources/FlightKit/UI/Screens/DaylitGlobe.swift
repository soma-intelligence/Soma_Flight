import SceneKit
import SwiftUI

/// The sign in globe by day: MapKit only draws its globe as night satellite imagery on black space, so light
/// mode gets its own. A SceneKit sphere wrapped in NASA's Blue Marble (public domain, `EarthDay.jpg`, 2048 by
/// 1024, equirectangular), lit by a soft sun from the upper left with a pale blue rim of atmosphere, on a clear
/// background so the page shows around it. Framed and turning like `SpinningGlobe`: latitude 34 at the centre,
/// starting at longitude -40, a third of a degree a second eastward, still when Reduce Motion is on.
struct DaylitGlobe: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            // The globe as the night map frames it: a disc a little wider than the screen, its top below the
            // status bar and its centre right of the middle, so the land behind the intro is the North Atlantic.
            let side = proxy.size.width * 1.96
            GlobeScene(spinning: !reduceMotion)
                .frame(width: side, height: side)
                .position(x: proxy.size.width * 0.6, y: proxy.size.height * 0.55)
        }
    }
}

/// The scene: a parent node tilted so latitude 34 faces the camera, the sphere spinning on its own axis inside.
@MainActor
final class GlobeSceneModel {
    static let latitude = 34.0
    static let startLongitude = -40.0
    /// Degrees of longitude per second, as `SpinningGlobe.speed`.
    static let speed = SpinningGlobe.speed
    static let spinKey = "spin"

    let scene = SCNScene()
    let earth: SCNNode

    init() {
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 96
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = Bundle.module.url(forResource: "EarthDay", withExtension: "jpg")
        material.diffuse.mipFilter = .linear
        material.diffuse.wrapS = .repeat
        // A pale blue rim where the surface turns away: the atmosphere seen edge on.
        material.shaderModifiers = [.fragment: """
            float rim = 1.0 - saturate(dot(normalize(_surface.normal), normalize(_surface.view)));
            _output.color.rgb = mix(_output.color.rgb, float3(0.70, 0.84, 1.0), pow(rim, 2.6) * 0.75);
            """]
        sphere.firstMaterial = material
        earth = SCNNode(geometry: sphere)
        // Turn the start longitude to face the camera (the -30 is where SCNSphere puts the texture seam).
        earth.eulerAngles = SCNVector3(0, Self.radians(-30 - Self.startLongitude), 0)

        let tilt = SCNNode()
        tilt.eulerAngles = SCNVector3(Self.radians(Self.latitude), 0, 0)
        tilt.addChildNode(earth)
        scene.rootNode.addChildNode(tilt)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 900
        sun.position = SCNVector3(-2, 1.6, 3)
        sun.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(sun)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 720
        scene.rootNode.addChildNode(ambient)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1.0
        camera.position = SCNVector3(0, 0, 5)
        scene.rootNode.addChildNode(camera)
        scene.background.contents = nil
    }

    func setSpinning(_ on: Bool) {
        if on, earth.action(forKey: Self.spinKey) == nil {
            // Eastward as the night map turns: the land drifts to the left.
            let turn = SCNAction.rotateBy(x: 0, y: -2 * .pi, z: 0, duration: 360 / Self.speed)
            earth.runAction(.repeatForever(turn), forKey: Self.spinKey)
        } else if !on {
            earth.removeAction(forKey: Self.spinKey)
        }
    }

    static func radians(_ degrees: Double) -> Float { Float(degrees * .pi / 180) }
}

@MainActor private func makeGlobeView(_ model: GlobeSceneModel) -> SCNView {
    let view = SCNView(frame: .zero)
    view.scene = model.scene
    view.pointOfView = model.scene.rootNode.childNodes.first { $0.camera != nil }
    view.antialiasingMode = .multisampling4X
    view.preferredFramesPerSecond = 30
    view.isPlaying = true
    view.allowsCameraControl = false
    view.backgroundColor = .clear
    #if os(iOS)
    view.isUserInteractionEnabled = false
    #endif
    return view
}

#if os(iOS)
private struct GlobeScene: UIViewRepresentable {
    let spinning: Bool
    func makeCoordinator() -> GlobeSceneModel { GlobeSceneModel() }
    func makeUIView(context: Context) -> SCNView { makeGlobeView(context.coordinator) }
    func updateUIView(_ view: SCNView, context: Context) { context.coordinator.setSpinning(spinning) }
}
#elseif os(macOS)
private struct GlobeScene: NSViewRepresentable {
    let spinning: Bool
    func makeCoordinator() -> GlobeSceneModel { GlobeSceneModel() }
    func makeNSView(context: Context) -> SCNView { makeGlobeView(context.coordinator) }
    func updateNSView(_ view: SCNView, context: Context) { context.coordinator.setSpinning(spinning) }
}
#endif
