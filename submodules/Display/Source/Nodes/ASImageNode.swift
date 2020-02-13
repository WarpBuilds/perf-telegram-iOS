import Foundation
import UIKit
import AsyncDisplayKit

open class ASImageNode: ASDisplayNode {
    public var image: UIImage? {
        didSet {
            if self.isNodeLoaded {
                self.contents = self.image?.cgImage
                //(self.view as? ASImageNodeView)?.image = self.image
            }
        }
    }

    public var displayWithoutProcessing: Bool = true

    override public init() {
        super.init()

        /*self.setViewBlock({
            return ASImageNodeView(frame: CGRect())
        })*/
    }

    override open func didLoad() {
        super.didLoad()

        //(self.view as? ASImageNodeView)?.image = self.image
    }
}
