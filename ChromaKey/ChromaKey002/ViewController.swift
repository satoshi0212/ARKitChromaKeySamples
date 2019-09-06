import CoreImage
import UIKit

class ViewController: UIViewController {

    @IBOutlet private weak var imageView: UIImageView!

    @IBOutlet private weak var backgroundImageView: UIImageView!

    @IBOutlet private weak var resultImageView: UIImageView!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        imageView.image = UIImage(named: "Image001")
        backgroundImageView.image = UIImage(named: "Image002")
    }

override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    if let foregroundImage = CIImage(image: imageView.image!),
        let backgroundImage = CIImage(image: backgroundImageView.image!) {

        if let resultCIImage = filter(foregroundCIImage: foregroundImage, backgroundCIImage: backgroundImage) {
            resultImageView.image = UIImage(ciImage: resultCIImage)
        }
    }
}

    private func filter(foregroundCIImage: CIImage, backgroundCIImage: CIImage) -> CIImage? {
        guard let chromaKeyCIFilter = ChromaKeyFilterFactory.make(fromHue: 0.3, toHue: 0.4),
            let compositor = CIFilter(name:"CISourceOverCompositing") else { return nil }

        chromaKeyCIFilter.setValue(foregroundCIImage, forKey: kCIInputImageKey)
        let sourceCIImageWithoutBackground = chromaKeyCIFilter.outputImage

        compositor.setValue(sourceCIImageWithoutBackground, forKey: kCIInputImageKey)
        compositor.setValue(backgroundCIImage, forKey: kCIInputBackgroundImageKey)
        let compositedCIImage = compositor.outputImage

        return compositedCIImage
    }
}
