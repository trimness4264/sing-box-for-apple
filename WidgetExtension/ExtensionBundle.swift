import SwiftUI
import WidgetKit

@main
struct ExtensionBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOSApplicationExtension 18.0, *) {
            ServiceToggleControl()
        }
    }
}
