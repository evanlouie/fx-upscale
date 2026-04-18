import Foundation

extension URL {
  /// Returns a sibling URL with the last path component renamed via `transform`.
  /// Preserves the existing path extension. If the URL has no extension, no trailing
  /// `"."` is appended.
  public func renamed(_ transform: (_ currentName: String) -> String) -> URL {
    let base = deletingLastPathComponent()
      .appending(component: transform(deletingPathExtension().lastPathComponent))
    let ext = pathExtension
    return ext.isEmpty ? base : base.appendingPathExtension(ext)
  }
}
