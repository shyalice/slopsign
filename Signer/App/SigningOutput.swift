import SwiftUI
import UIKit

/// A single native scroll view avoids estimated row heights and scrollTo calls
/// racing navigation transitions. New output preserves a reader's position.
struct SigningOutput: UIViewControllerRepresentable {
  let lines: [SigningLogLine]
  let runID: UUID
  func makeUIViewController(context: Context) -> Controller { Controller() }
  func updateUIViewController(_ controller: Controller, context: Context) { controller.update(lines, runID: runID) }

  final class Controller: UIViewController, UITextViewDelegate {
    let textView = UITextView(usingTextLayoutManager: false)
    private var runID: UUID?
    private var ids: [UUID] = []
    private var appeared = false
    private var followsOutput = true
    override func loadView() {
      view = textView
      textView.backgroundColor = .systemBackground
      textView.isEditable = false
      textView.isSelectable = true
      textView.alwaysBounceVertical = true
      textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
      textView.adjustsFontForContentSizeCategory = true
      textView.delegate = self
      textView.accessibilityIdentifier = "signing.output"
    }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      textView.layoutIfNeeded()
      textView.setContentOffset(CGPoint(x: 0, y: -textView.adjustedContentInset.top), animated: false)
      appeared = true
    }
    func update(_ lines: [SigningLogLine], runID: UUID) {
      loadViewIfNeeded()
      let newIDs = lines.map(\.id)
      guard self.runID != runID || ids != newIDs else { return }
      let reset = self.runID != runID || lines.count < ids.count || Array(newIDs.prefix(ids.count)) != ids
      let offset = textView.contentOffset
      let shouldFollow = appeared && followsOutput && !textView.isDragging && !textView.isDecelerating
      let newLines = reset ? lines : Array(lines.dropFirst(ids.count))
      if reset {
        textView.textStorage.setAttributedString(NSAttributedString())
        followsOutput = true
      }
      let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
      let text = NSMutableAttributedString()
      for line in newLines {
        text.append(NSAttributedString(string: line.text + "\n", attributes: [
          .font: font, .foregroundColor: line.isError ? UIColor.systemRed : UIColor.label
        ]))
      }
      textView.textStorage.append(text)
      textView.layoutManager.ensureLayout(for: textView.textContainer)
      textView.layoutIfNeeded()
      self.runID = runID; ids = newIDs
      if reset { textView.setContentOffset(CGPoint(x: 0, y: -textView.adjustedContentInset.top), animated: false) }
      else if shouldFollow {
        let bottom = max(-textView.adjustedContentInset.top, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
        textView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
      } else { textView.setContentOffset(offset, animated: false) }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate { updateFollowing() }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { followsOutput = false }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { updateFollowing() }
    private func updateFollowing() {
      followsOutput = textView.contentOffset.y + textView.bounds.height >= textView.contentSize.height + textView.adjustedContentInset.bottom - 24
    }
  }
}

extension View {
  @ViewBuilder func signingActionStyle(prominent: Bool = false) -> some View {
    if #available(iOS 26.0, *) {
      if prominent { self.buttonStyle(.glassProminent).controlSize(.large) }
      else { self.buttonStyle(.glass).controlSize(.large) }
    } else {
      if prominent { self.buttonStyle(.borderedProminent).controlSize(.large) }
      else { self.buttonStyle(.bordered).controlSize(.large) }
    }
  }
  @ViewBuilder func signingActionBar<Actions: View>(@ViewBuilder actions: @escaping () -> Actions) -> some View {
    GeometryReader { geometry in
      if #available(iOS 26.0, *) {
      self.toolbar {
        ToolbarItem(placement: .bottomBar) {
          ZStack { actions() }.frame(width: max(0, geometry.size.width - 32), height: 48)
        }
        .sharedBackgroundVisibility(.hidden)
      }
      .toolbar(.visible, for: .bottomBar)
    } else {
      self.toolbar {
        ToolbarItem(placement: .bottomBar) {
          ZStack { actions() }.frame(width: max(0, geometry.size.width - 32), height: 48)
        }
      }
      .toolbar(.visible, for: .bottomBar)
    }
    }
  }
}
