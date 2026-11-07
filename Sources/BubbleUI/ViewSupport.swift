// Owner: app/UI track. Small helpers shared by the views.
import SwiftUI

/// A binding over a plain value and a main-actor setter (views take values, not models).
/// The setter runs on the main actor: SwiftUI calls bindings there.
func bind<T: Sendable>(_ value: T, _ set: @escaping @MainActor @Sendable (T) -> Void) -> Binding<T> {
    Binding(get: { value }, set: { newValue in MainActor.assumeIsolated { set(newValue) } })
}
