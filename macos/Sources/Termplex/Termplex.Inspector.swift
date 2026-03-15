import TermplexKit
import Metal

extension Termplex {
    /// Represents the inspector for a surface within Termplex.
    ///
    /// Wraps a `termplex_inspector_t`
    final class Inspector: Sendable {
        private let inspector: termplex_inspector_t

        /// Read the underlying C value for this inspector. This is unsafe because the value will be
        /// freed when the Inspector class is deinitialized.
        var unsafeCValue: termplex_inspector_t {
            inspector
        }

        /// Initialize from the C structure.
        init(cInspector: termplex_inspector_t) {
            self.inspector = cInspector
        }

        /// Set the focus state of the inspector.
        @MainActor
        func setFocus(_ focused: Bool) {
            termplex_inspector_set_focus(inspector, focused)
        }

        /// Set the content scale of the inspector.
        @MainActor
        func setContentScale(x: Double, y: Double) {
            termplex_inspector_set_content_scale(inspector, x, y)
        }

        /// Set the size of the inspector.
        @MainActor
        func setSize(width: UInt32, height: UInt32) {
            termplex_inspector_set_size(inspector, width, height)
        }

        /// Send a mouse button event to the inspector.
        @MainActor
        func mouseButton(
            _ state: termplex_input_mouse_state_e,
            button: termplex_input_mouse_button_e,
            mods: termplex_input_mods_e
        ) {
            termplex_inspector_mouse_button(inspector, state, button, mods)
        }

        /// Send a mouse position event to the inspector.
        @MainActor
        func mousePos(x: Double, y: Double) {
            termplex_inspector_mouse_pos(inspector, x, y)
        }

        /// Send a mouse scroll event to the inspector.
        @MainActor
        func mouseScroll(x: Double, y: Double, mods: termplex_input_scroll_mods_t) {
            termplex_inspector_mouse_scroll(inspector, x, y, mods)
        }

        /// Send a key event to the inspector.
        @MainActor
        func key(
            _ action: termplex_input_action_e,
            key: termplex_input_key_e,
            mods: termplex_input_mods_e
        ) {
            termplex_inspector_key(inspector, action, key, mods)
        }

        /// Send text to the inspector.
        @MainActor
        func text(_ text: String) {
            text.withCString { ptr in
                termplex_inspector_text(inspector, ptr)
            }
        }

        /// Initialize Metal rendering for the inspector.
        @MainActor
        func metalInit(device: MTLDevice) -> Bool {
            let devicePtr = Unmanaged.passRetained(device).toOpaque()
            return termplex_inspector_metal_init(inspector, devicePtr)
        }

        /// Render the inspector using Metal.
        @MainActor
        func metalRender(
            commandBuffer: MTLCommandBuffer,
            descriptor: MTLRenderPassDescriptor
        ) {
            termplex_inspector_metal_render(
                inspector,
                Unmanaged.passRetained(commandBuffer).toOpaque(),
                Unmanaged.passRetained(descriptor).toOpaque()
            )
        }
    }
}
