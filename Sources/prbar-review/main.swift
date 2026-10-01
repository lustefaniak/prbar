import Foundation
// SwiftPM builds PRBarCore as a library; the Xcode `prbar-review` target
// (the copy bundled inside PRBar.app) compiles those sources into this
// module instead, so there is nothing to import there.
#if canImport(PRBarCore)
import PRBarCore
#endif

exit(await PRBarReviewCLI.main())
