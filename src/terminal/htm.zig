//! HTM (Headless Terminal Multiplexer) protocol support.
//!
//! When a surface prints `ESC[###q`, Ghostty enters HTM mode and maps native
//! tabs and splits onto `htmd` panes. Run `htm` (from Eternal Terminal) inside
//! a Ghostty surface to attach. Escape on the leader surface disconnects;
//! `x` shuts down the daemon.
//!
//! Optional config:
//!   * `htm-integration` — enable/disable takeover (default true)
//!   * `htm-bin-dir` — directory containing `htm`/`htmd`, prepended to PATH

const protocol = @import("htm/protocol.zig");
const state = @import("htm/state.zig");

pub const protocol_mod = protocol;
pub const Header = protocol.Header;
pub const Packet = protocol.Packet;
pub const Uuid = protocol.Uuid;
pub const UUID_LENGTH = protocol.UUID_LENGTH;
pub const init_seq = protocol.init_seq;
pub const exit_seq = protocol.exit_seq;
pub const encodeLength = protocol.encodeLength;
pub const decodeLength = protocol.decodeLength;
pub const longestInitPrefix = protocol.longestInitPrefix;
pub const consumeInitPayload = protocol.consumeInitPayload;
pub const parsePackets = protocol.parsePackets;
pub const parseOne = protocol.parseOne;
pub const encodePacket = protocol.encodePacket;
pub const encodeInsertKeys = protocol.encodeInsertKeys;
pub const encodeInsertDebugKeys = protocol.encodeInsertDebugKeys;
pub const encodeNewTab = protocol.encodeNewTab;
pub const encodeNewSplit = protocol.encodeNewSplit;
pub const encodeClientClosePane = protocol.encodeClientClosePane;
pub const encodeResizePane = protocol.encodeResizePane;
pub const parseUuid = protocol.parseUuid;
pub const generateUuid = protocol.generateUuid;
pub const decodeBase64 = protocol.decodeBase64;

pub const InitState = state.InitState;
pub const Tab = state.Tab;
pub const Pane = state.Pane;
pub const Split = state.Split;
pub const parseInitState = state.parse;

pub const Viewer = @import("htm/viewer.zig").Viewer;
pub const Action = @import("htm/viewer.zig").Action;

test {
    _ = protocol;
    _ = state;
    _ = @import("htm/viewer.zig");
}
