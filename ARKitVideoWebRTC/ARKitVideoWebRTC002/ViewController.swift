//
//  ViewController.swift
//  ARKitVideoWebRTC002
//
//  Created by satoshi0212 on 2019/09/05.
//  Copyright © 2019 SHMD. All rights reserved.
//

import UIKit
import SceneKit
import ARKit
import AVFoundation
import MetalKit
import SkyWay

class ViewController: UIViewController, ARSCNViewDelegate {

    @IBOutlet var sceneView: ARSCNView!

    let skywayAPIKey: String = ""
    let skywayDomain: String = "localhost"

    private var device: MTLDevice!
    private var videoMetalView: VideoMetalView!
    private var displayLink: CADisplayLink!

    private var remoteStreamView: SKWVideo?

    fileprivate var peer: SKWPeer?
    fileprivate var mediaConnection: SKWMediaConnection?
    fileprivate var localStream: SKWMediaStream?
    fileprivate var remoteStream: SKWMediaStream?

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.device = device

        self.setup()

        sceneView.delegate = self
        sceneView.showsStatistics = true
        sceneView.scene = SCNScene()

        videoMetalView = VideoMetalView(frame: CGRect(x: 0, y: 0, width: 812, height: 375), device: device)
        view.addSubview(videoMetalView)

        let videoPlane = SCNPlane(width: 1, height: 0.5625)
        videoPlane.firstMaterial?.diffuse.contents = videoMetalView
        videoPlane.firstMaterial?.isDoubleSided = true

        let videoPlaneNode = SCNNode(geometry: videoPlane)
        videoPlaneNode.position = SCNVector3(0, 0, -2)
        sceneView.scene.rootNode.addChildNode(videoPlaneNode)

        displayLink = CADisplayLink(target: self, selector: #selector(ViewController.display))
        displayLink.add(to: RunLoop.current, forMode: RunLoop.Mode.common)

        remoteStreamView = SKWVideo(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        //        remoteStreamView?.isHidden = true
        view.addSubview(remoteStreamView!)
        view.sendSubviewToBack(remoteStreamView!)

        let callButton = UIButton(frame: CGRect(x: 60, y: 600, width: 120, height: 40))
        callButton.setTitle("Call", for: .normal)
        callButton.addTarget(self, action:#selector(self.tapCall), for: .touchUpInside)
        view.addSubview(callButton)

        let endCallButton = UIButton(frame: CGRect(x: 220, y: 600, width: 120, height: 40))
        endCallButton.setTitle("EndCall", for: .normal)
        endCallButton.addTarget(self, action:#selector(self.tapEndCall), for: .touchUpInside)
        view.addSubview(endCallButton)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        let configuration = ARWorldTrackingConfiguration()
        sceneView.session.run(configuration)
        displayLink.isPaused = false
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        sceneView.session.pause()
        displayLink.isPaused = true

        self.mediaConnection?.close()
        self.peer?.destroy()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        videoMetalView.updateThreadgroupsPerGrid()
        videoMetalView.updateDrawableSize()
    }

    @objc func tapCall() {
        guard let peer = self.peer else { return }
        Util.callPeerIDSelectDialog(peer: peer, myPeerId: peer.identity) { (peerId) in
            self.call(targetPeerId: peerId)
        }
    }

    @objc func tapEndCall() {
        self.mediaConnection?.close()
    }

    @objc func display() {
        guard let v = remoteStreamView else { return }
        videoMetalView.updateTexture(targetView: v)
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
}

// MARK: - VideoMetalView

class VideoMetalView: MTKView {

    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var ciContext: CIContext!

    private var pipelineState: MTLComputePipelineState!
    private var defaultLibrary: MTLLibrary!
    private var commandQueue: MTLCommandQueue!
    private var threadsPerThreadgroup: MTLSize!
    private var threadgroupsPerGrid: MTLSize!

    private var inTexture: MTLTexture?
    private var bufferMtkView: MTKView!
    private var videoTextureCache: CVMetalTextureCache?

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?

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

        do {
            pipelineState = try device.makeComputePipelineState(function: defaultLibrary.makeFunction(name: "ChromaKeyFilter")!)
        } catch {
            fatalError("Unable to create pipeline state")
        }

        threadsPerThreadgroup = MTLSizeMake(16, 16, 1)

        bufferMtkView = MTKView(frame: frame, device: device)
        bufferMtkView.translatesAutoresizingMaskIntoConstraints = false
        bufferMtkView.framebufferOnly = false
        bufferMtkView.isHidden = true
        addSubview(bufferMtkView)

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &videoTextureCache)
    }

//    func setupPlayer(url: URL) {
//        player = AVPlayer(url: url)
//        player!.actionAtItemEnd = AVPlayer.ActionAtItemEnd.none
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(VideoMetalView.didPlayToEnd),
//                                               name: NSNotification.Name("AVPlayerItemDidPlayToEndTimeNotification"),
//                                               object: player!.currentItem)
//    }
//
//    func play() {
//        player?.play()
//    }
//
//    func pause() {
//        player?.pause()
//    }

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

    func updateTexture(targetView: UIView) {
        guard let tempDrawable = bufferMtkView.currentDrawable,
            let image = makeCurrentViewImage(targetView: targetView) else { return }
        let bounds = CGRect(origin: CGPoint.zero, size: self.bounds.size)
        ciContext.render(image, to: tempDrawable.texture, commandBuffer: nil, bounds: bounds, colorSpace: colorSpace)
        inTexture = tempDrawable.texture
        colorPixelFormat = tempDrawable.texture.pixelFormat
    }

    override func draw(_ dirtyRect: CGRect) {
        guard let device = device,
            let drawable = currentDrawable,
            let inTexture = inTexture else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let commandEncoder = commandBuffer.makeComputeCommandEncoder()!

        commandEncoder.setComputePipelineState(pipelineState)

        commandEncoder.setTexture(inTexture, index: 0)
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
            let videoItem = player.currentItem else { return nil }

        if videoOutput == nil || playerItem != videoItem {
            videoItem.outputs.compactMap({ return $0 as? AVPlayerItemVideoOutput }).forEach {
                videoItem.remove($0)
            }
            if videoItem.status != AVPlayerItem.Status.readyToPlay {
                return nil
            }

            let pixelBuffAttributes = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ] as [String: Any]

            let videoOutput = AVPlayerItemVideoOutput.init(pixelBufferAttributes: pixelBuffAttributes)
            videoItem.add(videoOutput)
            self.videoOutput = videoOutput
            self.playerItem = videoItem
        }

        guard let videoOutput = self.videoOutput else { return nil }

        let time = videoItem.currentTime()
        if !videoOutput.hasNewPixelBuffer(forItemTime: time) { return nil }

        let _pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)

        guard let pixelBuffer = _pixelBuffer else { return nil }
        return CIImage(cvPixelBuffer: pixelBuffer)
    }

private func makeCurrentViewImage(targetView: UIView) -> CIImage? {
    UIGraphicsBeginImageContextWithOptions(targetView.frame.size, true, 0)
    targetView.drawHierarchy(in: targetView.bounds, afterScreenUpdates: false)
    let image = UIGraphicsGetImageFromCurrentImageContext()!
    UIGraphicsEndImageContext();
    return CIImage(image: image)
}

    @objc private func didPlayToEnd(notification: NSNotification) {
        let item: AVPlayerItem = notification.object as! AVPlayerItem
        item.seek(to: CMTime.zero, completionHandler: nil)
    }
}

// MARK: setup skyway

extension ViewController {

    func setup() {
        let option: SKWPeerOption = SKWPeerOption.init();
        option.key = skywayAPIKey
        option.domain = skywayDomain

        peer = SKWPeer(options: option)

        if let _peer = peer{
            self.setupPeerCallBacks(peer: _peer)
            self.setupStream(peer: _peer)
        }else{
            print("failed to create peer setup")
        }
    }

    func setupStream(peer:SKWPeer){
        SKWNavigator.initialize(peer);
        //        let constraints:SKWMediaConstraints = SKWMediaConstraints()
        //        self.localStream = SKWNavigator.getUserMedia(constraints)
        //        self.localStream?.addVideoRenderer(self.localStreamView, track: 0)
    }

    func call(targetPeerId:String){
        let option = SKWCallOption()

        if let mediaConnection = self.peer?.call(withId: targetPeerId, stream: self.localStream, options: option){
            self.mediaConnection = mediaConnection
            self.setupMediaConnectionCallbacks(mediaConnection: mediaConnection)
        }else{
            print("failed to call :\(targetPeerId)")
        }
    }
}

// MARK: skyway callbacks

extension ViewController {

    func setupPeerCallBacks(peer:SKWPeer){

        // MARK: PEER_EVENT_ERROR
        peer.on(SKWPeerEventEnum.PEER_EVENT_ERROR, callback:{ (obj) -> Void in
            if let error = obj as? SKWPeerError{
                print("\(error)")
            }
        })

        // MARK: PEER_EVENT_OPEN
        peer.on(SKWPeerEventEnum.PEER_EVENT_OPEN,callback:{ (obj) -> Void in
            if let peerId = obj as? String{
                print("your peerId: \(peerId)")
            }
        })

        // MARK: PEER_EVENT_CONNECTION
        peer.on(SKWPeerEventEnum.PEER_EVENT_CALL, callback: { (obj) -> Void in
            if let connection = obj as? SKWMediaConnection{
                self.setupMediaConnectionCallbacks(mediaConnection: connection)
                self.mediaConnection = connection
                connection.answer(self.localStream)
            }
        })
    }

    func setupMediaConnectionCallbacks(mediaConnection:SKWMediaConnection){

        // MARK: MEDIACONNECTION_EVENT_STREAM
        mediaConnection.on(SKWMediaConnectionEventEnum.MEDIACONNECTION_EVENT_STREAM, callback: { (obj) -> Void in
            if let msStream = obj as? SKWMediaStream{
                self.remoteStream = msStream
                DispatchQueue.main.async {
                    if let remoteStreamView = self.remoteStreamView {
                        self.remoteStream?.addVideoRenderer(remoteStreamView, track: 0)
                    }
                }
            }
        })

        // MARK: MEDIACONNECTION_EVENT_CLOSE
        mediaConnection.on(SKWMediaConnectionEventEnum.MEDIACONNECTION_EVENT_CLOSE, callback: { (obj) -> Void in
            if let _ = obj as? SKWMediaConnection{
                DispatchQueue.main.async {
                    if let remoteStreamView = self.remoteStreamView {
                        self.remoteStream?.removeVideoRenderer(remoteStreamView, track: 0)
                    }
                    self.remoteStream = nil
                    self.mediaConnection = nil
                }
            }
        })
    }
}
