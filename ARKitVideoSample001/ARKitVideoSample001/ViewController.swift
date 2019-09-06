import ARKit
import SceneKit
import UIKit

class ViewController: UIViewController, ARSCNViewDelegate {

    @IBOutlet var sceneView: ARSCNView!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        sceneView.delegate = self
        sceneView.scene = SCNScene()
        sceneView.showsStatistics = true

        let videoUrl = Bundle.main.url(forResource: "MikaRika", withExtension: "mp4")!
        let videoNode = createVideoNode(size: 1, videoUrl: videoUrl)
        videoNode.position = SCNVector3(0, 0, -1)
        sceneView.scene.rootNode.addChildNode(videoNode)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        let configuration = ARWorldTrackingConfiguration()
        sceneView.session.run(configuration)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        sceneView.session.pause()
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

extension ViewController {

    @objc func didPlayToEnd(notification: NSNotification) {
        let item: AVPlayerItem = notification.object as! AVPlayerItem
        item.seek(to: CMTime.zero, completionHandler: nil)
    }

    func createVideoNode(size: CGFloat, videoUrl: URL) -> SCNNode {
        let skSceneSize = CGSize(width: 1024, height: 1024) // サイズが小さいとビデオの解像度が落ちる

        // AVPlayer生成
        let avPlayer = AVPlayer(url: videoUrl)
        avPlayer.actionAtItemEnd = AVPlayer.ActionAtItemEnd.none
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(ViewController.didPlayToEnd),
                                               name: NSNotification.Name("AVPlayerItemDidPlayToEndTimeNotification"),
                                               object: avPlayer.currentItem)

        // SKVideoNode生成
        // シーンと同じサイズとし、中央に配置する
        let skVideoNode = SKVideoNode(avPlayer: avPlayer)
        skVideoNode.position = CGPoint(x: skSceneSize.width / 2.0, y: skSceneSize.height / 2.0)
        skVideoNode.size = skSceneSize
        skVideoNode.yScale = -1.0 // 座標系を上下逆にする
        skVideoNode.play() // 再生開始

        // SKScene生成
        let skScene = SKScene(size: skSceneSize)
        skScene.addChild(skVideoNode)

        // SCNMaterial生成
        let material = SCNMaterial()
        material.diffuse.contents = skScene
        material.isDoubleSided = true

        // SCNNode生成
        let node = SCNNode()
        node.geometry = SCNPlane(width: size, height: size) // SCNPlane(=SCNGeometryを継承したクラス)生成
        node.geometry?.materials = [material]
        node.scale = SCNVector3(1, 0.5625, 1)
        return node
    }
}
