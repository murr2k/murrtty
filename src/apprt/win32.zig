//! Application runtime for native Windows, built directly on Win32
//! (user32/gdi32) with WGL rendering.

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = @import("../os/main.zig").resourcesDir;

/// Called first thing in main, before global state is initialized.
pub fn preInit() void {
    @import("win32/console.zig").attachForCli();
}

test {
    _ = @import("win32/AlertDialog.zig");
    _ = @import("win32/ClipboardDialog.zig");
    _ = @import("win32/CommandPalette.zig");
    _ = @import("win32/ContextMenu.zig");
    _ = @import("win32/HeaderBar.zig");
    _ = @import("win32/TitleDialog.zig");
    _ = @import("win32/draw.zig");
    _ = @import("win32/DropTarget.zig");
    _ = @import("win32/GlobalKeys.zig");
    _ = @import("win32/gl_diagnosis.zig");
    _ = @import("win32/ipc.zig");
    _ = @import("win32/jump_list.zig");
    _ = @import("win32/KeyState.zig");
    _ = @import("win32/QuickTerminal.zig");
    _ = @import("win32/Notifications.zig");
    _ = @import("win32/Overlay.zig");
    _ = @import("win32/PaneDrag.zig");
    _ = @import("win32/Undo.zig");
    _ = @import("win32/Inspector.zig");
    _ = @import("win32/key.zig");
    _ = @import("win32/split_layout.zig");
    _ = @import("win32/TabBar.zig");
    _ = @import("win32/text.zig");
    _ = @import("win32/url.zig");
}
