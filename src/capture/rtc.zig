/// Zig bindings for libdatachannel C API
/// WebRTC DataChannel for receiving frames from Chrome extension
const std = @import("std");
const c = @cImport({
    @cInclude("rtc/rtc.h");
});

// Re-export C types
pub const State = enum(c_int) {
    new = c.RTC_NEW,
    connecting = c.RTC_CONNECTING,
    connected = c.RTC_CONNECTED,
    disconnected = c.RTC_DISCONNECTED,
    failed = c.RTC_FAILED,
    closed = c.RTC_CLOSED,
};

pub const IceState = enum(c_int) {
    new = c.RTC_ICE_NEW,
    checking = c.RTC_ICE_CHECKING,
    connected = c.RTC_ICE_CONNECTED,
    completed = c.RTC_ICE_COMPLETED,
    failed = c.RTC_ICE_FAILED,
    disconnected = c.RTC_ICE_DISCONNECTED,
    closed = c.RTC_ICE_CLOSED,
};

pub const GatheringState = enum(c_int) {
    new = c.RTC_GATHERING_NEW,
    in_progress = c.RTC_GATHERING_INPROGRESS,
    complete = c.RTC_GATHERING_COMPLETE,
};

pub const LogLevel = enum(c_int) {
    none = c.RTC_LOG_NONE,
    fatal = c.RTC_LOG_FATAL,
    err = c.RTC_LOG_ERROR,
    warning = c.RTC_LOG_WARNING,
    info = c.RTC_LOG_INFO,
    debug = c.RTC_LOG_DEBUG,
    verbose = c.RTC_LOG_VERBOSE,
};

// Error codes
pub const ERR_SUCCESS = c.RTC_ERR_SUCCESS;
pub const ERR_INVALID = c.RTC_ERR_INVALID;
pub const ERR_FAILURE = c.RTC_ERR_FAILURE;
pub const ERR_NOT_AVAIL = c.RTC_ERR_NOT_AVAIL;
pub const ERR_TOO_SMALL = c.RTC_ERR_TOO_SMALL;

pub const Error = error{
    Invalid,
    Failure,
    NotAvailable,
    BufferTooSmall,
};

fn checkError(result: c_int) Error!c_int {
    return switch (result) {
        ERR_INVALID => error.Invalid,
        ERR_FAILURE => error.Failure,
        ERR_NOT_AVAIL => error.NotAvailable,
        ERR_TOO_SMALL => error.BufferTooSmall,
        else => result,
    };
}

/// Initialize the logger
pub fn initLogger(level: LogLevel, callback: ?*const fn (LogLevel, [*:0]const u8) callconv(.c) void) void {
    c.rtcInitLogger(@as(c_uint, @intCast(@intFromEnum(level))), @ptrCast(callback));
}

/// Preload libdatachannel (optional, called automatically on first use)
pub fn preload() void {
    c.rtcPreload();
}

/// Cleanup libdatachannel resources
pub fn cleanup() void {
    c.rtcCleanup();
}

/// PeerConnection wrapper
pub const PeerConnection = struct {
    id: c_int,

    pub const Config = struct {
        ice_servers: ?[]const [*:0]const u8 = null,
    };

    pub fn create(config: Config) Error!PeerConnection {
        var rtc_config: c.rtcConfiguration = std.mem.zeroes(c.rtcConfiguration);

        if (config.ice_servers) |servers| {
            rtc_config.iceServers = @ptrCast(@constCast(servers.ptr));
            rtc_config.iceServersCount = @intCast(servers.len);
        }

        const id = try checkError(c.rtcCreatePeerConnection(&rtc_config));
        return .{ .id = id };
    }

    pub fn close(self: PeerConnection) void {
        _ = c.rtcClosePeerConnection(self.id);
    }

    pub fn delete(self: PeerConnection) void {
        _ = c.rtcDeletePeerConnection(self.id);
    }

    /// Set user pointer for callbacks
    pub fn setUserPointer(self: PeerConnection, ptr: ?*anyopaque) void {
        c.rtcSetUserPointer(self.id, ptr);
    }

    /// Get user pointer
    pub fn getUserPointer(self: PeerConnection) ?*anyopaque {
        return c.rtcGetUserPointer(self.id);
    }

    /// Set callback for local description (SDP offer/answer)
    pub fn setLocalDescriptionCallback(
        self: PeerConnection,
        callback: ?*const fn (c_int, [*:0]const u8, [*:0]const u8, ?*anyopaque) callconv(.c) void,
    ) Error!void {
        _ = try checkError(c.rtcSetLocalDescriptionCallback(self.id, @ptrCast(callback)));
    }

    /// Set callback for local ICE candidates
    pub fn setLocalCandidateCallback(
        self: PeerConnection,
        callback: ?*const fn (c_int, [*:0]const u8, [*:0]const u8, ?*anyopaque) callconv(.c) void,
    ) Error!void {
        _ = try checkError(c.rtcSetLocalCandidateCallback(self.id, @ptrCast(callback)));
    }

    /// Set callback for state changes
    pub fn setStateChangeCallback(
        self: PeerConnection,
        callback: ?*const fn (c_int, c_int, ?*anyopaque) callconv(.c) void,
    ) Error!void {
        _ = try checkError(c.rtcSetStateChangeCallback(self.id, @ptrCast(callback)));
    }

    /// Set callback for ICE state changes
    pub fn setIceStateChangeCallback(
        self: PeerConnection,
        callback: ?*const fn (c_int, c_int, ?*anyopaque) callconv(.c) void,
    ) Error!void {
        _ = try checkError(c.rtcSetIceStateChangeCallback(self.id, @ptrCast(callback)));
    }

    /// Set callback for gathering state changes
    pub fn setGatheringStateChangeCallback(
        self: PeerConnection,
        callback: ?*const fn (c_int, c_int, ?*anyopaque) callconv(.c) void,
    ) Error!void {
        _ = try checkError(c.rtcSetGatheringStateChangeCallback(self.id, @ptrCast(callback)));
    }

    /// Set callback for incoming data channels
    pub fn setDataChannelCallback(
        self: PeerConnection,
        callback: ?*const fn (c_int, c_int, ?*anyopaque) callconv(.c) void,
    ) Error!void {
        _ = try checkError(c.rtcSetDataChannelCallback(self.id, @ptrCast(callback)));
    }

    /// Set local description (triggers offer/answer generation)
    pub fn setLocalDescription(self: PeerConnection, desc_type: ?[*:0]const u8) Error!void {
        _ = try checkError(c.rtcSetLocalDescription(self.id, desc_type));
    }

    /// Set remote description (SDP from peer)
    pub fn setRemoteDescription(self: PeerConnection, sdp: [*:0]const u8, desc_type: [*:0]const u8) Error!void {
        _ = try checkError(c.rtcSetRemoteDescription(self.id, sdp, desc_type));
    }

    /// Add remote ICE candidate
    pub fn addRemoteCandidate(self: PeerConnection, candidate: [*:0]const u8, mid: [*:0]const u8) Error!void {
        _ = try checkError(c.rtcAddRemoteCandidate(self.id, candidate, mid));
    }

    /// Get local description
    pub fn getLocalDescription(self: PeerConnection, buffer: []u8) Error![]u8 {
        const len = try checkError(c.rtcGetLocalDescription(self.id, buffer.ptr, @intCast(buffer.len)));
        return buffer[0..@intCast(len)];
    }

    /// Create a data channel
    pub fn createDataChannel(self: PeerConnection, label: [*:0]const u8) Error!DataChannel {
        const id = try checkError(c.rtcCreateDataChannel(self.id, label));
        return .{ .id = id };
    }
};

/// DataChannel wrapper
pub const DataChannel = struct {
    id: c_int,

    /// Set user pointer for callbacks
    pub fn setUserPointer(self: DataChannel, ptr: ?*anyopaque) void {
        c.rtcSetUserPointer(self.id, ptr);
    }

    /// Get user pointer
    pub fn getUserPointer(self: DataChannel) ?*anyopaque {
        return c.rtcGetUserPointer(self.id);
    }

    /// Set callback for when channel opens
    pub fn setOpenCallback(
        self: DataChannel,
        callback: ?*const fn (c_int, ?*anyopaque) callconv(.c) void,
    ) Error!void {
        _ = try checkError(c.rtcSetOpenCallback(self.id, @ptrCast(callback)));
    }

    /// Set callback for when channel closes
    pub fn setClosedCallback(
        self: DataChannel,
        callback: ?*const fn (c_int, ?*anyopaque) callconv(.c) void,
    ) Error!void {
        _ = try checkError(c.rtcSetClosedCallback(self.id, @ptrCast(callback)));
    }

    /// Set callback for errors
    pub fn setErrorCallback(
        self: DataChannel,
        callback: ?*const fn (c_int, [*:0]const u8, ?*anyopaque) callconv(.c) void,
    ) Error!void {
        _ = try checkError(c.rtcSetErrorCallback(self.id, @ptrCast(callback)));
    }

    /// Set callback for messages
    pub fn setMessageCallback(
        self: DataChannel,
        callback: ?*const fn (c_int, [*]const u8, c_int, ?*anyopaque) callconv(.c) void,
    ) Error!void {
        _ = try checkError(c.rtcSetMessageCallback(self.id, @ptrCast(callback)));
    }

    /// Send a message
    pub fn sendMessage(self: DataChannel, data: []const u8) Error!void {
        _ = try checkError(c.rtcSendMessage(self.id, data.ptr, @intCast(data.len)));
    }

    /// Check if channel is open
    pub fn isOpen(self: DataChannel) bool {
        return c.rtcIsOpen(self.id);
    }

    /// Check if channel is closed
    pub fn isClosed(self: DataChannel) bool {
        return c.rtcIsClosed(self.id);
    }

    /// Close the channel
    pub fn close(self: DataChannel) void {
        _ = c.rtcClose(self.id);
    }

    /// Delete the channel
    pub fn delete(self: DataChannel) void {
        _ = c.rtcDelete(self.id);
    }

    /// Get buffered amount
    pub fn getBufferedAmount(self: DataChannel) c_int {
        return c.rtcGetBufferedAmount(self.id);
    }

    /// Get label
    pub fn getLabel(self: DataChannel, buffer: []u8) Error![]u8 {
        const len = try checkError(c.rtcGetDataChannelLabel(self.id, buffer.ptr, @intCast(buffer.len)));
        return buffer[0..@intCast(len)];
    }
};

// Tests
test "rtc bindings compile" {
    // Just check that the bindings compile
    _ = PeerConnection;
    _ = DataChannel;
}
