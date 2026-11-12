import SwiftUI
import UIKit

/// UIKit's standard glass button inside the navigation controller's toolbar.
struct SigningActionButton: UIViewRepresentable {
  let title: String
  var prominent = false
  var enabled = true
  var identifier: String? = nil
  let action: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> UIButton {
    let button = UIButton(type: .system)
    button.addAction(UIAction { [weak coordinator = context.coordinator] _ in coordinator?.action() }, for: .touchUpInside)
    return button
  }
  func updateUIView(_ button: UIButton, context: Context) {
    context.coordinator.action = action
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) { configuration = prominent ? .prominentGlass() : .glass() }
    else { configuration = prominent ? .filled() : .tinted() }
    configuration.title = title
    configuration.cornerStyle = .capsule
    configuration.buttonSize = .large
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    configuration.titleLineBreakMode = .byTruncatingTail
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var attributes = incoming
      attributes.font = UIFont.preferredFont(forTextStyle: .body)
      return attributes
    }
    if prominent { configuration.baseForegroundColor = .white }
    button.configuration = configuration
    button.titleLabel?.numberOfLines = 1
    button.titleLabel?.adjustsFontSizeToFitWidth = true
    button.titleLabel?.minimumScaleFactor = 0.75
    button.isEnabled = enabled
    button.accessibilityIdentifier = identifier
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: 48)
  }
  final class Coordinator { var action: () -> Void = {} }
}
