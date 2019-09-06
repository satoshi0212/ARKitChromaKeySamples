import AVFoundation
import MetalKit
import UIKit

class ViewController: UIViewController {

    private let captureSession = AVCaptureSession()
    private let videoDevice = AVCaptureDevice.default(for: .video)!
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var videoOutput = AVCaptureVideoDataOutput()

    private var mtkView: MTKView!
    private var device: MTLDevice!
    private var videoTextureCache: CVMetalTextureCache?
    private var metalView: VideoMetalView!
    private var screenSize: CGSize!
    private var ciContext: CIContext!
    private var thresholdSlider: UISlider!

    override func viewDidLoad() {
        super.viewDidLoad()

        let imageView = UIImageView(frame: CGRect.zero)
        imageView.image = UIImage(named: "background")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        thresholdSlider = UISlider(frame: CGRect.zero)
        thresholdSlider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thresholdSlider)

        view.addConstraints([imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                             imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                             imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                             imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 16/9),
                             thresholdSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                             thresholdSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                             thresholdSlider.topAnchor.constraint(equalTo: imageView.bottomAnchor),
                             thresholdSlider.heightAnchor.constraint(equalToConstant: 40)])

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice) as AVCaptureDeviceInput
            captureSession.addInput(videoInput)
        } catch let error as NSError {
            print(error)
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as AnyHashable as! String : Int(kCVPixelFormatType_32BGRA)]

        captureSession.sessionPreset = AVCaptureSession.Preset.hd1920x1080

        let queue = DispatchQueue(label: "myqueue", attributes: .concurrent)
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        captureSession.addOutput(videoOutput)

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.device = device

        if let videoConnection = videoOutput.connection(with: .video),
            videoConnection.isVideoOrientationSupported {
            videoConnection.videoOrientation = .portrait
        }

        ciContext = CIContext(mtlDevice: device)

        setMaxFps()

        metalView = VideoMetalView(frame: CGRect.zero, device: device, thresholdSlider: thresholdSlider)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.framebufferOnly = false
        metalView.isOpaque = false
        view.addSubview(metalView)
        view.addConstraints([metalView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
                             metalView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
                             metalView.topAnchor.constraint(equalTo: imageView.topAnchor),
                             metalView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor)])

        mtkView = MTKView(frame: CGRect.zero, device: device)
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        mtkView.framebufferOnly = false
        mtkView.isHidden = true
        view.addSubview(mtkView)
        view.addConstraints([mtkView.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
                             mtkView.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
                             mtkView.topAnchor.constraint(equalTo: metalView.topAnchor),
                             mtkView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor)])

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &videoTextureCache)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        metalView.updateThreadgroupsPerGrid()
        metalView.drawableSize = metalView.bounds.size
        mtkView.drawableSize = mtkView.bounds.size

        screenSize = metalView.bounds.size
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        captureSession.startRunning()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        captureSession.stopRunning()
    }

    private func setMaxFps() {
        var minFPS = 0.0
        var maxFPS = 0.0
        var maxWidth: Int32 = 0
        var selectedFormat: AVCaptureDevice.Format? = nil

        for format in videoDevice.formats {
            for range in format.videoSupportedFrameRateRanges {
                let desc = format.formatDescription
                let dimentions = CMVideoFormatDescriptionGetDimensions(desc)

                if (minFPS <= range.minFrameRate && maxFPS <= range.maxFrameRate && maxWidth <= dimentions.width) {
                    minFPS = range.minFrameRate
                    maxFPS = range.maxFrameRate
                    maxWidth = dimentions.width
                    selectedFormat = format
                }
            }
        }

        do {
            try videoDevice.lockForConfiguration()
            videoDevice.activeFormat = selectedFormat!
            videoDevice.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: 60)
            videoDevice.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: 60)
            videoDevice.unlockForConfiguration()
        } catch {
            print(error)
        }
    }
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {

func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
        let tempDrawable = mtkView.currentDrawable,
        let ciContext = ciContext else { return }

    let image = CIImage(cvPixelBuffer: pixelBuffer)
    let bounds = CGRect(origin: CGPoint.zero, size: screenSize)
    let scaleX = bounds.size.width / image.extent.width
    let scaleY = bounds.size.height / image.extent.height
    let scale = min(scaleX, scaleY)
    let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    ciContext.render(scaledImage, to: tempDrawable.texture, commandBuffer: nil, bounds: bounds, colorSpace: colorSpace)
    metalView.updateTexture(texture: tempDrawable.texture)
}
}

final class VideoMetalView: MTKView {
    var inTexture: MTLTexture?

    var pipelineState: MTLComputePipelineState!
    var defaultLibrary: MTLLibrary!
    var commandQueue: MTLCommandQueue!
    var threadsPerThreadgroup: MTLSize!
    var threadgroupsPerGrid: MTLSize!

    private var thresholdSlider: UISlider!

    required init(frame: CGRect, device: MTLDevice, thresholdSlider: UISlider) {
        super.init(frame: frame, device: device)

        self.thresholdSlider = thresholdSlider

        defaultLibrary = device.makeDefaultLibrary()!
        commandQueue = device.makeCommandQueue()

        let kernelFunction = defaultLibrary.makeFunction(name: "ChromaKeyFilter")

        do {
            pipelineState = try device.makeComputePipelineState(function: kernelFunction!)
        } catch {
            fatalError("Unable to create pipeline state")
        }

        threadsPerThreadgroup = MTLSizeMake(16, 16, 1)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateThreadgroupsPerGrid() {
        threadgroupsPerGrid = MTLSizeMake(
            Int(ceilf(Float(frame.width) / Float(threadsPerThreadgroup.width))),
            Int(ceilf(Float(frame.height) / Float(threadsPerThreadgroup.height))),
            1)
    }

    func updateTexture(texture: MTLTexture) {
        inTexture = texture
        colorPixelFormat = texture.pixelFormat
    }

override func draw(_ dirtyRect: CGRect) {
    guard let device = device,
        let drawable = currentDrawable,
        let inTexture = inTexture else {
            return
    }

    let commandBuffer = commandQueue.makeCommandBuffer()!
    let commandEncoder = commandBuffer.makeComputeCommandEncoder()!

    commandEncoder.setComputePipelineState(pipelineState)

    commandEncoder.setTexture(inTexture, index: 0)
    commandEncoder.setTexture(drawable.texture, index: 1)

    let factors: [Float] = [0,
                            1,
                            0,
                            thresholdSlider.value,
                            0.1]
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
}
