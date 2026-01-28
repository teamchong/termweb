///
/// Native system metrics for termweb dashboard
/// Cross-platform (Linux/macOS) using direct OS APIs for maximum performance
///
const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Node-API Types and Functions
// ============================================================================

const napi_env = *opaque {};
const napi_value = *opaque {};
const napi_callback_info = *opaque {};
const napi_status = enum(c_int) { ok = 0, invalid_arg = 1, object_expected = 2, string_expected = 3, name_expected = 4, function_expected = 5, number_expected = 6, boolean_expected = 7, array_expected = 8, generic_failure = 9 };

extern fn napi_create_object(env: napi_env, result: *napi_value) napi_status;
extern fn napi_create_double(env: napi_env, value: f64, result: *napi_value) napi_status;
extern fn napi_create_int32(env: napi_env, value: i32, result: *napi_value) napi_status;
extern fn napi_create_string_utf8(env: napi_env, str: [*]const u8, length: usize, result: *napi_value) napi_status;
extern fn napi_create_array_with_length(env: napi_env, length: usize, result: *napi_value) napi_status;
extern fn napi_set_named_property(env: napi_env, object: napi_value, utf8name: [*:0]const u8, value: napi_value) napi_status;
extern fn napi_set_element(env: napi_env, object: napi_value, index: u32, value: napi_value) napi_status;
extern fn napi_get_undefined(env: napi_env, result: *napi_value) napi_status;
extern fn napi_throw_error(env: napi_env, code: ?[*:0]const u8, msg: [*:0]const u8) napi_status;
extern fn napi_create_function(env: napi_env, utf8name: ?[*:0]const u8, length: usize, cb: *const fn (napi_env, napi_callback_info) callconv(.c) napi_value, data: ?*anyopaque, result: *napi_value) napi_status;

// ============================================================================
// C imports for system APIs
// ============================================================================

const c = @cImport({
    @cInclude("sys/statvfs.h");
    @cInclude("dirent.h");
    @cInclude("unistd.h");
    if (builtin.os.tag == .macos) {
        @cInclude("mach/mach.h");
        @cInclude("mach/mach_host.h");
        @cInclude("mach/mach_time.h");
        @cInclude("mach/host_info.h");
        @cInclude("mach/processor_info.h");
        @cInclude("mach/vm_statistics.h");
        @cInclude("mach/vm_map.h");
        @cInclude("mach/task_info.h");
        @cInclude("sys/sysctl.h");
        @cInclude("sys/proc_info.h");
        @cInclude("libproc.h");
        @cInclude("net/if.h");
        @cInclude("ifaddrs.h");
    }
});

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// ============================================================================
// CPU Statistics
// ============================================================================

pub const CpuStats = struct { user: u64, nice: u64, system: u64, idle: u64, iowait: u64 };

fn getCpuStats() !CpuStats {
    return if (builtin.os.tag == .linux) getLinuxCpu() else if (builtin.os.tag == .macos) getMacCpu() else error.UnsupportedOs;
}

fn getCoreStats(allocator: std.mem.Allocator) ![]CpuStats {
    return if (builtin.os.tag == .linux) getLinuxCores(allocator) else if (builtin.os.tag == .macos) getMacCores(allocator) else error.UnsupportedOs;
}

fn getLinuxCpu() !CpuStats {
    var file = try std.fs.openFileAbsolute("/proc/stat", .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    var lines = std.mem.tokenizeScalar(u8, buf[0..bytes_read], '\n');
    return parseLinuxCpuLine(lines.next() orelse return error.ParseError);
}

fn getLinuxCores(allocator: std.mem.Allocator) ![]CpuStats {
    var file = try std.fs.openFileAbsolute("/proc/stat", .{});
    defer file.close();
    var buf: [16384]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    var cores: std.ArrayListUnmanaged(CpuStats) = .{};
    defer cores.deinit(allocator);
    var lines = std.mem.tokenizeScalar(u8, buf[0..bytes_read], '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu")) break;
        try cores.append(allocator, parseLinuxCpuLine(line) catch continue);
    }
    return try cores.toOwnedSlice(allocator);
}

fn parseLinuxCpuLine(line: []const u8) !CpuStats {
    var iter = std.mem.tokenizeAny(u8, line, " \t");
    _ = iter.next();
    return CpuStats{
        .user = try std.fmt.parseInt(u64, iter.next() orelse "0", 10),
        .nice = try std.fmt.parseInt(u64, iter.next() orelse "0", 10),
        .system = try std.fmt.parseInt(u64, iter.next() orelse "0", 10),
        .idle = try std.fmt.parseInt(u64, iter.next() orelse "0", 10),
        .iowait = try std.fmt.parseInt(u64, iter.next() orelse "0", 10),
    };
}

fn getMacCpu() !CpuStats {
    var cpu_load: c.host_cpu_load_info_data_t = undefined;
    var count: c.mach_msg_type_number_t = c.HOST_CPU_LOAD_INFO_COUNT;
    if (c.host_statistics(c.mach_host_self(), c.HOST_CPU_LOAD_INFO, @ptrCast(&cpu_load), &count) != c.KERN_SUCCESS) return error.MachError;
    return CpuStats{ .user = cpu_load.cpu_ticks[c.CPU_STATE_USER], .nice = cpu_load.cpu_ticks[c.CPU_STATE_NICE], .system = cpu_load.cpu_ticks[c.CPU_STATE_SYSTEM], .idle = cpu_load.cpu_ticks[c.CPU_STATE_IDLE], .iowait = 0 };
}

fn getMacCores(allocator: std.mem.Allocator) ![]CpuStats {
    var processor_info: c.processor_cpu_load_info_t = undefined;
    var processor_count: c.natural_t = 0;
    var processor_info_count: c.mach_msg_type_number_t = 0;
    if (c.host_processor_info(c.mach_host_self(), c.PROCESSOR_CPU_LOAD_INFO, &processor_count, @ptrCast(&processor_info), &processor_info_count) != c.KERN_SUCCESS) return error.MachError;
    defer _ = c.vm_deallocate(c.mach_task_self(), @intFromPtr(processor_info), processor_info_count * @sizeOf(c.natural_t));
    var cores = try allocator.alloc(CpuStats, processor_count);
    for (0..processor_count) |i| {
        const info = processor_info[i];
        cores[i] = CpuStats{ .user = info.cpu_ticks[c.CPU_STATE_USER], .nice = info.cpu_ticks[c.CPU_STATE_NICE], .system = info.cpu_ticks[c.CPU_STATE_SYSTEM], .idle = info.cpu_ticks[c.CPU_STATE_IDLE], .iowait = 0 };
    }
    return cores;
}

// ============================================================================
// Memory Statistics
// ============================================================================

pub const MemStats = struct { total: u64, free: u64, available: u64, used: u64, swap_total: u64, swap_used: u64 };

fn getMemStats() !MemStats {
    return if (builtin.os.tag == .linux) getLinuxMem() else if (builtin.os.tag == .macos) getMacMem() else error.UnsupportedOs;
}

fn getLinuxMem() !MemStats {
    var file = try std.fs.openFileAbsolute("/proc/meminfo", .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    var total: u64 = 0;
    var free: u64 = 0;
    var available: u64 = 0;
    var buffers: u64 = 0;
    var cached: u64 = 0;
    var swap_total: u64 = 0;
    var swap_free: u64 = 0;
    var lines = std.mem.tokenizeScalar(u8, buf[0..bytes_read], '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, ": \t");
        const key = parts.next() orelse continue;
        const value = (std.fmt.parseInt(u64, parts.next() orelse continue, 10) catch continue) * 1024;
        if (std.mem.eql(u8, key, "MemTotal")) total = value else if (std.mem.eql(u8, key, "MemFree")) free = value else if (std.mem.eql(u8, key, "MemAvailable")) available = value else if (std.mem.eql(u8, key, "Buffers")) buffers = value else if (std.mem.eql(u8, key, "Cached")) cached = value else if (std.mem.eql(u8, key, "SwapTotal")) swap_total = value else if (std.mem.eql(u8, key, "SwapFree")) swap_free = value;
    }
    if (available == 0) available = free + buffers + cached;
    return MemStats{ .total = total, .free = free, .available = available, .used = total - available, .swap_total = swap_total, .swap_used = swap_total - swap_free };
}

fn getMacMem() !MemStats {
    var total: u64 = 0;
    var size: usize = @sizeOf(u64);
    var mib = [_]c_int{ c.CTL_HW, c.HW_MEMSIZE };
    if (c.sysctl(&mib, 2, &total, &size, null, 0) != 0) return error.SysctlError;
    var vm_stat: c.vm_statistics64_data_t = undefined;
    var count: c.mach_msg_type_number_t = c.HOST_VM_INFO64_COUNT;
    if (c.host_statistics64(c.mach_host_self(), c.HOST_VM_INFO64, @ptrCast(&vm_stat), &count) != c.KERN_SUCCESS) return error.MachError;
    const page_size: u64 = 4096;
    const free = vm_stat.free_count * page_size;
    const available = free + vm_stat.inactive_count * page_size + vm_stat.speculative_count * page_size;
    var swap: c.xsw_usage = undefined;
    var swap_size: usize = @sizeOf(c.xsw_usage);
    var swap_mib = [_]c_int{ c.CTL_VM, c.VM_SWAPUSAGE };
    _ = c.sysctl(&swap_mib, 2, &swap, &swap_size, null, 0);
    return MemStats{ .total = total, .free = free, .available = available, .used = total - available, .swap_total = swap.xsu_total, .swap_used = swap.xsu_used };
}

// ============================================================================
// Disk Statistics
// ============================================================================

pub const DiskStats = struct { mount: [128]u8, mount_len: usize, fs: [64]u8, fs_len: usize, total: u64, used: u64, available: u64 };

fn getDiskStats(allocator: std.mem.Allocator) ![]DiskStats {
    return if (builtin.os.tag == .linux) getLinuxDisks(allocator) else if (builtin.os.tag == .macos) getMacDisks(allocator) else error.UnsupportedOs;
}

fn getLinuxDisks(allocator: std.mem.Allocator) ![]DiskStats {
    var file = try std.fs.openFileAbsolute("/proc/mounts", .{});
    defer file.close();
    var buf: [8192]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    var disks: std.ArrayListUnmanaged(DiskStats) = .{};
    defer disks.deinit(allocator);
    var lines = std.mem.tokenizeScalar(u8, buf[0..bytes_read], '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const device = parts.next() orelse continue;
        const mount = parts.next() orelse continue;
        const fstype = parts.next() orelse continue;
        if (!std.mem.startsWith(u8, device, "/dev/")) continue;
        if (std.mem.startsWith(u8, mount, "/snap") or std.mem.startsWith(u8, mount, "/boot")) continue;
        // Need null-terminated string for statvfs
        var mount_z: [256]u8 = undefined;
        if (mount.len >= mount_z.len) continue;
        @memcpy(mount_z[0..mount.len], mount);
        mount_z[mount.len] = 0;
        var stat: c.struct_statvfs = undefined;
        if (c.statvfs(&mount_z, &stat) != 0) continue;
        const block_size: u64 = stat.f_frsize;
        const total = stat.f_blocks * block_size;
        if (total < 1024 * 1024 * 1024) continue;
        var disk = DiskStats{ .mount = undefined, .mount_len = 0, .fs = undefined, .fs_len = 0, .total = total, .used = (stat.f_blocks - stat.f_bfree) * block_size, .available = stat.f_bavail * block_size };
        const ml = @min(mount.len, disk.mount.len - 1);
        @memcpy(disk.mount[0..ml], mount[0..ml]);
        disk.mount[ml] = 0;
        disk.mount_len = ml;
        const fl = @min(fstype.len, disk.fs.len - 1);
        @memcpy(disk.fs[0..fl], fstype[0..fl]);
        disk.fs[fl] = 0;
        disk.fs_len = fl;
        try disks.append(allocator, disk);
    }
    return try disks.toOwnedSlice(allocator);
}

fn getMacDisks(allocator: std.mem.Allocator) ![]DiskStats {
    var disks: std.ArrayListUnmanaged(DiskStats) = .{};
    defer disks.deinit(allocator);
    const mounts = [_][*:0]const u8{ "/", "/System/Volumes/Data" };
    for (mounts) |mount| {
        var stat: c.struct_statvfs = undefined;
        if (c.statvfs(mount, &stat) != 0) continue;
        const block_size: u64 = stat.f_frsize;
        const total = stat.f_blocks * block_size;
        if (total < 1024 * 1024 * 1024) continue;
        var disk = DiskStats{ .mount = undefined, .mount_len = 0, .fs = undefined, .fs_len = 0, .total = total, .used = (stat.f_blocks - stat.f_bfree) * block_size, .available = stat.f_bavail * block_size };
        const mount_slice = std.mem.span(mount);
        const ml = @min(mount_slice.len, disk.mount.len - 1);
        @memcpy(disk.mount[0..ml], mount_slice[0..ml]);
        disk.mount[ml] = 0;
        disk.mount_len = ml;
        const fs_name = "apfs";
        @memcpy(disk.fs[0..fs_name.len], fs_name);
        disk.fs[fs_name.len] = 0;
        disk.fs_len = fs_name.len;
        try disks.append(allocator, disk);
    }
    return try disks.toOwnedSlice(allocator);
}

// ============================================================================
// Network Statistics
// ============================================================================

pub const NetStats = struct { iface: [32]u8, iface_len: usize, rx_bytes: u64, tx_bytes: u64 };

fn getNetStats(allocator: std.mem.Allocator) ![]NetStats {
    return if (builtin.os.tag == .linux) getLinuxNet(allocator) else if (builtin.os.tag == .macos) getMacNet(allocator) else error.UnsupportedOs;
}

fn getLinuxNet(allocator: std.mem.Allocator) ![]NetStats {
    var file = try std.fs.openFileAbsolute("/proc/net/dev", .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    var nets: std.ArrayListUnmanaged(NetStats) = .{};
    defer nets.deinit(allocator);
    var lines = std.mem.tokenizeScalar(u8, buf[0..bytes_read], '\n');
    _ = lines.next();
    _ = lines.next();
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, ": \t");
        const iface = parts.next() orelse continue;
        if (std.mem.eql(u8, iface, "lo")) continue;
        const rx_bytes = std.fmt.parseInt(u64, parts.next() orelse continue, 10) catch continue;
        for (0..7) |_| _ = parts.next();
        const tx_bytes = std.fmt.parseInt(u64, parts.next() orelse continue, 10) catch continue;
        var net = NetStats{ .iface = undefined, .iface_len = 0, .rx_bytes = rx_bytes, .tx_bytes = tx_bytes };
        const il = @min(iface.len, net.iface.len - 1);
        @memcpy(net.iface[0..il], iface[0..il]);
        net.iface[il] = 0;
        net.iface_len = il;
        try nets.append(allocator, net);
    }
    return try nets.toOwnedSlice(allocator);
}

fn getMacNet(allocator: std.mem.Allocator) ![]NetStats {
    var nets: std.ArrayListUnmanaged(NetStats) = .{};
    defer nets.deinit(allocator);
    var ifap: ?*c.struct_ifaddrs = null;
    if (c.getifaddrs(&ifap) != 0) return try nets.toOwnedSlice(allocator);
    defer c.freeifaddrs(ifap);
    var ifa = ifap;
    while (ifa) |addr| : (ifa = addr.ifa_next) {
        if (addr.ifa_addr == null or addr.ifa_addr.*.sa_family != c.AF_LINK or addr.ifa_data == null) continue;
        const name = std.mem.span(addr.ifa_name);
        if (std.mem.eql(u8, name, "lo0")) continue;
        const data: *c.struct_if_data = @ptrCast(@alignCast(addr.ifa_data));
        var net = NetStats{ .iface = undefined, .iface_len = 0, .rx_bytes = data.ifi_ibytes, .tx_bytes = data.ifi_obytes };
        const il = @min(name.len, net.iface.len - 1);
        @memcpy(net.iface[0..il], name[0..il]);
        net.iface[il] = 0;
        net.iface_len = il;
        try nets.append(allocator, net);
    }
    return try nets.toOwnedSlice(allocator);
}

// ============================================================================
// Process Statistics
// ============================================================================

pub const ProcStats = struct { pid: i32, name: [64]u8, name_len: usize, cpu_time: u64, mem_rss: u64, state: u8 };

fn getProcessStats(allocator: std.mem.Allocator, max_procs: usize) ![]ProcStats {
    return if (builtin.os.tag == .linux) getLinuxProcs(allocator, max_procs) else if (builtin.os.tag == .macos) getMacProcs(allocator, max_procs) else error.UnsupportedOs;
}

fn getLinuxProcs(allocator: std.mem.Allocator, max_procs: usize) ![]ProcStats {
    var procs: std.ArrayListUnmanaged(ProcStats) = .{};
    errdefer procs.deinit(allocator);
    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return try procs.toOwnedSlice(allocator);
    defer proc_dir.close();
    var iter = proc_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        var path_buf: [64]u8 = undefined;
        const stat_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch continue;
        var stat_file = std.fs.openFileAbsolute(stat_path, .{}) catch continue;
        defer stat_file.close();
        var stat_buf: [512]u8 = undefined;
        const stat_len = stat_file.readAll(&stat_buf) catch continue;
        const stat_data = stat_buf[0..stat_len];
        const name_start = std.mem.indexOf(u8, stat_data, "(") orelse continue;
        const name_end = std.mem.lastIndexOf(u8, stat_data, ")") orelse continue;
        if (name_end <= name_start + 1) continue;
        const name = stat_data[name_start + 1 .. name_end];
        if (name_end + 2 >= stat_data.len) continue;
        const after_name = stat_data[name_end + 2 ..];
        var parts = std.mem.tokenizeScalar(u8, after_name, ' ');
        const state_str = parts.next() orelse continue;
        const state = if (state_str.len > 0) state_str[0] else 'S';
        for (0..10) |_| _ = parts.next();
        const utime = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;
        const stime = std.fmt.parseInt(u64, parts.next() orelse "0", 10) catch 0;
        const statm_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/statm", .{pid}) catch continue;
        var statm_file = std.fs.openFileAbsolute(statm_path, .{}) catch continue;
        defer statm_file.close();
        var statm_buf: [128]u8 = undefined;
        const statm_len = statm_file.readAll(&statm_buf) catch continue;
        var statm_parts = std.mem.tokenizeScalar(u8, statm_buf[0..statm_len], ' ');
        _ = statm_parts.next();
        const rss_pages = std.fmt.parseInt(u64, statm_parts.next() orelse "0", 10) catch 0;
        var proc = ProcStats{ .pid = pid, .name = undefined, .name_len = 0, .cpu_time = utime + stime, .mem_rss = rss_pages * 4096, .state = state };
        const nl = @min(name.len, proc.name.len - 1);
        @memcpy(proc.name[0..nl], name[0..nl]);
        proc.name[nl] = 0;
        proc.name_len = nl;
        try procs.append(allocator, proc);
    }
    // Don't sort by cumulative time - JS will sort by current CPU% after delta calculation
    if (procs.items.len > max_procs) procs.shrinkRetainingCapacity(max_procs);
    return try procs.toOwnedSlice(allocator);
}

// Get Mach timebase ratio to convert Mach absolute time to nanoseconds
// On Apple Silicon, ratio is typically 125/3 = 41.67
var mach_timebase_numer: u32 = 1;
var mach_timebase_denom: u32 = 1;
var mach_timebase_initialized: bool = false;

fn initMachTimebase() void {
    if (mach_timebase_initialized) return;
    var info: c.mach_timebase_info_data_t = undefined;
    if (c.mach_timebase_info(&info) == c.KERN_SUCCESS) {
        mach_timebase_numer = info.numer;
        mach_timebase_denom = info.denom;
    }
    mach_timebase_initialized = true;
}

fn machTimeToNanos(mach_time: u64) u64 {
    initMachTimebase();
    // Convert using the timebase ratio: nanos = mach_time * numer / denom
    return mach_time * mach_timebase_numer / mach_timebase_denom;
}

fn getMacProcs(allocator: std.mem.Allocator, max_procs: usize) ![]ProcStats {
    var procs: std.ArrayListUnmanaged(ProcStats) = .{};
    errdefer procs.deinit(allocator);
    var pids: [2048]c.pid_t = undefined;
    const pid_count = c.proc_listallpids(&pids, @sizeOf(@TypeOf(pids)));
    if (pid_count <= 0) return try procs.toOwnedSlice(allocator);
    const num_pids: usize = @intCast(@divFloor(pid_count, @sizeOf(c.pid_t)));
    for (pids[0..num_pids]) |pid| {
        if (pid <= 0) continue;
        var pinfo: c.struct_proc_taskallinfo = undefined;
        const size = c.proc_pidinfo(pid, c.PROC_PIDTASKALLINFO, 0, &pinfo, @sizeOf(@TypeOf(pinfo)));
        if (size <= 0) continue;
        // Convert Mach time to nanoseconds for accurate CPU percentage calculation
        const cpu_time_mach = pinfo.ptinfo.pti_total_user + pinfo.ptinfo.pti_total_system;
        var proc = ProcStats{
            .pid = pid,
            .name = undefined,
            .name_len = 0,
            .cpu_time = machTimeToNanos(cpu_time_mach),
            .mem_rss = pinfo.ptinfo.pti_resident_size,
            .state = switch (pinfo.pbsd.pbi_status) {
                2 => 'R',
                1, 3 => 'S',
                4 => 'T',
                5 => 'Z',
                else => 'S',
            },
        };
        const name_slice = std.mem.sliceTo(&pinfo.pbsd.pbi_name, 0);
        const nl = @min(name_slice.len, proc.name.len - 1);
        @memcpy(proc.name[0..nl], name_slice[0..nl]);
        proc.name[nl] = 0;
        proc.name_len = nl;
        try procs.append(allocator, proc);
    }
    // Don't sort by cumulative time - JS will sort by current CPU% after delta calculation
    if (procs.items.len > max_procs) procs.shrinkRetainingCapacity(max_procs);
    return try procs.toOwnedSlice(allocator);
}

// ============================================================================
// NAPI Exports
// ============================================================================

fn napi_getCpuStats(env: napi_env, _: napi_callback_info) callconv(.c) napi_value {
    const stats = getCpuStats() catch return napiUndefined(env);
    var obj: napi_value = undefined;
    _ = napi_create_object(env, &obj);
    setDouble(env, obj, "user", stats.user);
    setDouble(env, obj, "nice", stats.nice);
    setDouble(env, obj, "system", stats.system);
    setDouble(env, obj, "idle", stats.idle);
    setDouble(env, obj, "iowait", stats.iowait);
    return obj;
}

fn napi_getMemStats(env: napi_env, _: napi_callback_info) callconv(.c) napi_value {
    const stats = getMemStats() catch return napiUndefined(env);
    var obj: napi_value = undefined;
    _ = napi_create_object(env, &obj);
    setDouble(env, obj, "total", stats.total);
    setDouble(env, obj, "free", stats.free);
    setDouble(env, obj, "available", stats.available);
    setDouble(env, obj, "used", stats.used);
    setDouble(env, obj, "swapTotal", stats.swap_total);
    setDouble(env, obj, "swapUsed", stats.swap_used);
    return obj;
}

fn napi_getCoreStats(env: napi_env, _: napi_callback_info) callconv(.c) napi_value {
    const allocator = gpa.allocator();
    const cores = getCoreStats(allocator) catch return napiUndefined(env);
    defer allocator.free(cores);
    var arr: napi_value = undefined;
    _ = napi_create_array_with_length(env, cores.len, &arr);
    for (cores, 0..) |stats, i| {
        var obj: napi_value = undefined;
        _ = napi_create_object(env, &obj);
        setDouble(env, obj, "user", stats.user);
        setDouble(env, obj, "nice", stats.nice);
        setDouble(env, obj, "system", stats.system);
        setDouble(env, obj, "idle", stats.idle);
        setDouble(env, obj, "iowait", stats.iowait);
        _ = napi_set_element(env, arr, @intCast(i), obj);
    }
    return arr;
}

fn napi_getDiskStats(env: napi_env, _: napi_callback_info) callconv(.c) napi_value {
    const allocator = gpa.allocator();
    const disks = getDiskStats(allocator) catch return napiUndefined(env);
    defer allocator.free(disks);
    var arr: napi_value = undefined;
    _ = napi_create_array_with_length(env, disks.len, &arr);
    for (disks, 0..) |disk, i| {
        var obj: napi_value = undefined;
        _ = napi_create_object(env, &obj);
        setString(env, obj, "mount", disk.mount[0..disk.mount_len]);
        setString(env, obj, "fs", disk.fs[0..disk.fs_len]);
        setDouble(env, obj, "total", disk.total);
        setDouble(env, obj, "used", disk.used);
        setDouble(env, obj, "available", disk.available);
        _ = napi_set_element(env, arr, @intCast(i), obj);
    }
    return arr;
}

fn napi_getNetStats(env: napi_env, _: napi_callback_info) callconv(.c) napi_value {
    const allocator = gpa.allocator();
    const nets = getNetStats(allocator) catch return napiUndefined(env);
    defer allocator.free(nets);
    var arr: napi_value = undefined;
    _ = napi_create_array_with_length(env, nets.len, &arr);
    for (nets, 0..) |net, i| {
        var obj: napi_value = undefined;
        _ = napi_create_object(env, &obj);
        setString(env, obj, "iface", net.iface[0..net.iface_len]);
        setDouble(env, obj, "rxBytes", net.rx_bytes);
        setDouble(env, obj, "txBytes", net.tx_bytes);
        _ = napi_set_element(env, arr, @intCast(i), obj);
    }
    return arr;
}

fn napi_getProcessStats(env: napi_env, _: napi_callback_info) callconv(.c) napi_value {
    const allocator = gpa.allocator();
    // Return all processes (up to 2000) - JS will sort by current CPU% after delta calculation
    const procs = getProcessStats(allocator, 2000) catch return napiUndefined(env);
    defer allocator.free(procs);
    var arr: napi_value = undefined;
    _ = napi_create_array_with_length(env, procs.len, &arr);
    for (procs, 0..) |proc, i| {
        var obj: napi_value = undefined;
        _ = napi_create_object(env, &obj);
        setInt(env, obj, "pid", proc.pid);
        setString(env, obj, "name", proc.name[0..proc.name_len]);
        setDouble(env, obj, "cpuTime", proc.cpu_time);
        setDouble(env, obj, "memRss", proc.mem_rss);
        setString(env, obj, "state", &[_]u8{proc.state});
        _ = napi_set_element(env, arr, @intCast(i), obj);
    }
    return arr;
}

fn napiUndefined(env: napi_env) napi_value {
    var undef: napi_value = undefined;
    _ = napi_get_undefined(env, &undef);
    return undef;
}

fn setDouble(env: napi_env, obj: napi_value, name: [*:0]const u8, value: u64) void {
    var val: napi_value = undefined;
    _ = napi_create_double(env, @floatFromInt(value), &val);
    _ = napi_set_named_property(env, obj, name, val);
}

fn setInt(env: napi_env, obj: napi_value, name: [*:0]const u8, value: i32) void {
    var val: napi_value = undefined;
    _ = napi_create_int32(env, value, &val);
    _ = napi_set_named_property(env, obj, name, val);
}

fn setString(env: napi_env, obj: napi_value, name: [*:0]const u8, value: []const u8) void {
    var val: napi_value = undefined;
    _ = napi_create_string_utf8(env, value.ptr, value.len, &val);
    _ = napi_set_named_property(env, obj, name, val);
}

export fn napi_register_module_v1(env: napi_env, exports: napi_value) napi_value {
    const funcs = [_]struct { name: [*:0]const u8, len: usize, func: *const fn (napi_env, napi_callback_info) callconv(.c) napi_value }{
        .{ .name = "getCpuStats", .len = 11, .func = &napi_getCpuStats },
        .{ .name = "getMemStats", .len = 11, .func = &napi_getMemStats },
        .{ .name = "getCoreStats", .len = 12, .func = &napi_getCoreStats },
        .{ .name = "getDiskStats", .len = 12, .func = &napi_getDiskStats },
        .{ .name = "getNetStats", .len = 11, .func = &napi_getNetStats },
        .{ .name = "getProcessStats", .len = 15, .func = &napi_getProcessStats },
    };
    for (funcs) |f| {
        var func: napi_value = undefined;
        _ = napi_create_function(env, f.name, f.len, f.func, null, &func);
        _ = napi_set_named_property(env, exports, f.name, func);
    }
    return exports;
}
