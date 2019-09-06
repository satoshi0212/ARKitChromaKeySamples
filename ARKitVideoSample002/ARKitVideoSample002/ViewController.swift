import ARKit
import MetalKit
import SceneKit
import UIKit

class ViewController: UIViewController, ARSCNViewDelegate {

    @IBOutlet var sceneView: ARSCNView!

    private var device: MTLDevice!
    private var videoMetalView: VideoMetalView!
    private let videoURL = URL(fileURLWithPath: Bundle.main.path(forResource: "MikaRika", ofType:"mp4")!)

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.device = device

        sceneView.delegate = self
        sceneView.showsStatistics = true
        sceneView.scene = SCNScene()

        let resolution = resolutionForLocalVideo(url: videoURL)
        guard let videoWidth = resolution?.width, let videoHeight = resolution?.height else {
            return
        }

        let rect = CGRect(x: 0, y: 0, width: videoWidth, height: videoHeight)
        videoMetalView = VideoMetalView(frame: rect, device: device)
        view.addSubview(videoMetalView)

        let videoPlane = SCNPlane(width: 1, height: CGFloat(videoHeight / videoWidth))
        videoPlane.firstMaterial?.diffuse.contents = videoMetalView
        videoPlane.firstMaterial?.isDoubleSided = true

        let videoPlaneNode = SCNNode(geometry: videoPlane)
        videoPlaneNode.position = SCNVector3(0, 0, -2)
        sceneView.scene.rootNode.addChildNode(videoPlaneNode)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = .horizontal
        sceneView.session.run(configuration)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        videoMetalView.setupPlayer(url: videoURL)
        videoMetalView.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        sceneView.session.pause()
        videoMetalView.pause()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        videoMetalView.updateThreadgroupsPerGrid()
        videoMetalView.updateDrawableSize()
    }

    // MARK: - ARSCNViewDelegate
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required
    }

    // MARK: - Private

    private func resolutionForLocalVideo(url: URL) -> CGSize? {
        guard let track = AVURLAsset(url: url).tracks(withMediaType: AVMediaType.video).first else { return nil }
        let size = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }
}

// MARK: - VideoMetalView

class VideoMetalView: MTKView {

    private let colorSpace = CGColorSpaceCreateDeviceRGB()
private let videoOutput = AVPlayerItemVideoOutput.init(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ] as [String: Any])

    private var ciContext: CIContext!
    private var player: AVPlayer?
    private var bufferMtkView: MTKView!

    private var pipelineState: MTLComputePipelineState!
    private var defaultLibrary: MTLLibrary!
    private var commandQueue: MTLCommandQueue!
    private var threadsPerThreadgroup: MTLSize!
    private var threadgroupsPerGrid: MTLSize!

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    required init(frame: CGRect, device: MTLDevice) {

        ciContext = CIContext(mtlDevice: device)

        super.init(frame: frame, device: device)

        framebufferOnly = false
        isOpaque = false
        backgroundColor = .clear

        commandQueue = device.makeCommandQueue()
        defaultLibrary = device.makeDefaultLibrary()!
        pipelineState = try! device.makeComputePipelineState(function: defaultLibrary.makeFunction(name: "ChromaKeyFilter")!)
        threadsPerThreadgroup = MTLSizeMake(16, 16, 1)

        bufferMtkView = MTKView(frame: frame, device: device)
        bufferMtkView.translatesAutoresizingMaskIntoConstraints = false
        bufferMtkView.framebufferOnly = false
        bufferMtkView.isHidden = true
        addSubview(bufferMtkView)
    }

func setupPlayer(url: URL) {
    player = AVPlayer(url: url)

    player!.actionAtItemEnd = AVPlayer.ActionAtItemEnd.none
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(VideoMetalView.didPlayToEnd),
                                           name: NSNotification.Name("AVPlayerItemDidPlayToEndTimeNotification"),
                                           object: player!.currentItem)

    guard let player = player,
        let videoItem = player.currentItem else { return }

    videoItem.add(videoOutput)
}

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func updateThreadgroupsPerGrid() {
        threadgroupsPerGrid = MTLSizeMake(
            Int(ceilf(Float(frame.width) / Float(threadsPerThreadgroup.width))),
            Int(ceilf(Float(frame.height) / Float(threadsPerThreadgroup.height))),
            1)
    }

    func updateDrawableSize() {
        drawableSize = bounds.size
        bufferMtkView.drawableSize = bufferMtkView.bounds.size
    }

override func draw(_ dirtyRect: CGRect) {

    guard let device = device,
        let drawable = currentDrawable,
        let tempDrawable = bufferMtkView.currentDrawable,
        let image = makeCurrentVideoImage() else { return }

    ciContext.render(image, to: tempDrawable.texture, commandBuffer: nil, bounds: bounds, colorSpace: colorSpace)
    colorPixelFormat = tempDrawable.texture.pixelFormat

    let commandBuffer = commandQueue.makeCommandBuffer()!
    let commandEncoder = commandBuffer.makeComputeCommandEncoder()!

    commandEncoder.setComputePipelineState(pipelineState)

    commandEncoder.setTexture(tempDrawable.texture, index: 0)
    commandEncoder.setTexture(drawable.texture, index: 1)

    let factors: [Float] = [
        0,    // red
        1,    // green
        0,    // blue
        0.43, // threshold
        0.11  // smoothing
    ]
    for i in 0..<factors.count {
        var factor = factors[i]
        let size = max(MemoryLayout<Float>.size, 16)
        let buffer = device.makeBuffer(
            bytes: &factor,
            length: size,
            options: [.storageModeShared]
        )
        commandEncoder.setBuffer(buffer, offset: 0, index: i)
    }

    commandEncoder.dispatchThreadgroups(threadgroupsPerGrid,
                                        threadsPerThreadgroup: threadsPerThreadgroup)
    commandEncoder.endEncoding()

    commandBuffer.present(drawable)
    commandBuffer.commit()
}

    private func makeCurrentVideoImage() -> CIImage? {
        guard let player = player,
            let videoItem = player.currentItem
            else { return nil }

        let time = videoItem.currentTime()

        guard
            videoOutput.hasNewPixelBuffer(forItemTime: time),
            let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time,
                                                          itemTimeForDisplay: nil)
            else { return nil }

        return CIImage(cvPixelBuffer: pixelBuffer)
    }

    @objc private func didPlayToEnd(notification: NSNotification) {
        let item: AVPlayerItem = notification.object as! AVPlayerItem
        item.seek(to: CMTime.zero, completionHandler: nil)
    }
}
