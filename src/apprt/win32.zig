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
    _ = @import("win32/CommandPalette.zig");
    _ = @import("win32/ContextMenu.zig");
    _ = @import("win32/TitleDialog.zig");
    _ = @import("win32/key.zig");
    _ = @import("win32/split_layout.zig");
    _ = @import("win32/TabBar.zig");
    _ = @import("win32/text.zig");
    _ = @import("win32/url.zig");
}
