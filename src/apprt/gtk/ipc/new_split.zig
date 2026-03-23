const std = @import("std");
const Allocator = std.mem.Allocator;

const glib = @import("glib");

const apprt = @import("../../../apprt.zig");
const DBus = @import("DBus.zig");

// Use a D-Bus method call to create a new split in the active window.
//
// `termplex +new-split` is equivalent to the following command (on a release build):
//
// ```
// gdbus call --session --dest com.termplex.app --object-path /com/mitchellh/termplex --method org.gtk.Actions.Activate new-split '[<"right">]' []
// ```
pub fn newSplit(alloc: Allocator, target: apprt.ipc.Target, value: apprt.ipc.Action.NewSplit) (Allocator.Error || std.Io.Writer.Error || apprt.ipc.Errors)!bool {
    var dbus = try DBus.init(
        alloc,
        target,
        "new-split",
    );
    defer dbus.deinit(alloc);

    // The direction string is sent as the first parameter.
    const s_variant_type = glib.VariantType.new("s");
    defer s_variant_type.free();

    const bytes = glib.Bytes.new(value.direction.ptr, value.direction.len + 1);
    defer bytes.unref();
    const direction_variant = glib.Variant.newFromBytes(s_variant_type, bytes, @intFromBool(true));
    dbus.addParameter(direction_variant);

    try dbus.send();

    return true;
}
