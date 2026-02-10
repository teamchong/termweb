//! Platform-specific context switching for goroutines.
//!
//! Provides save/restore of callee-saved registers and stack pointer,
//! enabling cooperative context switches between goroutines and the
//! scheduler. Uses inline assembly — no libc dependency.
//!
//! Supported architectures:
//! - x86_64: saves rbx, rbp, r12-r15, rsp, rip
//! - aarch64: saves x19-x30, sp

const std = @import("std");
const builtin = @import("builtin");

/// Saved CPU context for a goroutine.
/// Only callee-saved registers need saving — the caller-saved registers
/// are already handled by the calling convention at the point of swapContext().
pub const Context = switch (builtin.cpu.arch) {
    .x86_64 => extern struct {
        rsp: u64 = 0,
        rbp: u64 = 0,
        rbx: u64 = 0,
        r12: u64 = 0,
        r13: u64 = 0,
        r14: u64 = 0,
        r15: u64 = 0,
        rip: u64 = 0,
    },
    .aarch64 => extern struct {
        sp: u64 = 0,
        x19: u64 = 0,
        x20: u64 = 0,
        x21: u64 = 0,
        x22: u64 = 0,
        x23: u64 = 0,
        x24: u64 = 0,
        x25: u64 = 0,
        x26: u64 = 0,
        x27: u64 = 0,
        x28: u64 = 0,
        x29: u64 = 0, // frame pointer
        x30: u64 = 0, // link register (return address)
    },
    else => @compileError("Unsupported architecture for goroutine context switching"),
};

/// Save current execution context to `save`, then restore and jump to `restore`.
/// When another swapContext later restores `save`, execution resumes after
/// this call as if it had returned normally.
pub inline fn swapContext(save: *Context, restore: *const Context) void {
    switch (comptime builtin.cpu.arch) {
        .x86_64 => swapContextX86_64(save, restore),
        .aarch64 => swapContextAarch64(save, restore),
        else => @compileError("Unsupported architecture"),
    }
}

/// Initialize a context so that swapContext(_, ctx) starts executing
/// `func(arg)` on the provided stack. When func returns, on_exit is called.
pub fn makeContext(
    ctx: *Context,
    stack: []align(16) u8,
    func: *const fn (*anyopaque) void,
    arg: *anyopaque,
    on_exit: *const fn () callconv(.c) noreturn,
) void {
    switch (comptime builtin.cpu.arch) {
        .x86_64 => makeContextX86_64(ctx, stack, func, arg, on_exit),
        .aarch64 => makeContextAarch64(ctx, stack, func, arg, on_exit),
        else => @compileError("Unsupported architecture"),
    }
}

// ============================================================================
// x86_64 implementation
// ============================================================================

fn swapContextX86_64(save: *Context, restore: *const Context) void {
    // Pin save → rdi, restore → rsi; use movq for explicit 64-bit operations
    asm volatile (
    // Save callee-saved registers to save context
        \\movq %%rsp, 0x00(%%rdi)
        \\movq %%rbp, 0x08(%%rdi)
        \\movq %%rbx, 0x10(%%rdi)
        \\movq %%r12, 0x18(%%rdi)
        \\movq %%r13, 0x20(%%rdi)
        \\movq %%r14, 0x28(%%rdi)
        \\movq %%r15, 0x30(%%rdi)
        \\leaq 1f(%%rip), %%rax
        \\movq %%rax, 0x38(%%rdi)
        // Restore callee-saved registers from restore context
        \\movq 0x10(%%rsi), %%rbx
        \\movq 0x18(%%rsi), %%r12
        \\movq 0x20(%%rsi), %%r13
        \\movq 0x28(%%rsi), %%r14
        \\movq 0x30(%%rsi), %%r15
        \\movq 0x08(%%rsi), %%rbp
        \\movq 0x00(%%rsi), %%rsp
        \\jmpq *0x38(%%rsi)
        \\1:
        :
        : [save] "{rdi}" (save),
          [restore] "{rsi}" (restore),
        : .{ .rax = true, .rcx = true, .rdx = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true, .memory = true, .cc = true }
    );
}

fn makeContextX86_64(
    ctx: *Context,
    stack: []align(16) u8,
    func: *const fn (*anyopaque) void,
    arg: *anyopaque,
    on_exit: *const fn () callconv(.c) noreturn,
) void {
    // Stack layout at trampoline entry (rsp = ctx.rsp):
    //
    //   rsp must be 16-byte aligned before `call *r12` in the trampoline.
    //   System V ABI: at func entry (after call pushes return addr), rsp % 16 == 8.
    //   So before call: rsp % 16 == 0.
    //
    //   After func returns, trampoline calls on_exit (which is noreturn).
    //   r12 = func, r13 = arg, r14 = on_exit.
    const stack_top = @intFromPtr(stack.ptr) + stack.len;
    // 16-byte aligned rsp (no on_exit on stack — trampoline calls it via r14)
    const aligned = stack_top & ~@as(usize, 15);

    ctx.rsp = aligned;
    ctx.rbp = 0;
    ctx.rbx = 0;
    ctx.r12 = @intFromPtr(func);
    ctx.r13 = @intFromPtr(arg);
    ctx.r14 = @intFromPtr(on_exit);
    ctx.r15 = 0;
    ctx.rip = @intFromPtr(&trampolineX86_64);
}

/// Trampoline: calls func(arg), then calls on_exit().
/// r12 = func, r13 = arg, r14 = on_exit. All callee-saved across swapContext.
/// rsp is 16-aligned on entry. `call *r12` pushes return address making
/// rsp 8-mod-16 at func entry (correct per System V ABI).
/// After func returns, `call *r14` similarly gives on_exit correct alignment.
fn trampolineX86_64() callconv(.naked) void {
    asm volatile (
        \\movq %%r13, %%rdi
        \\callq *%%r12
        \\callq *%%r14
    );
}

// ============================================================================
// aarch64 implementation
// ============================================================================

fn swapContextAarch64(save: *Context, restore: *const Context) void {
    asm volatile (
    // Save callee-saved registers
        \\mov x2, sp
        \\str x2,  [%[save], #0x00]
        \\stp x19, x20, [%[save], #0x08]
        \\stp x21, x22, [%[save], #0x18]
        \\stp x23, x24, [%[save], #0x28]
        \\stp x25, x26, [%[save], #0x38]
        \\stp x27, x28, [%[save], #0x48]
        \\stp x29, x30, [%[save], #0x58]
        // Restore callee-saved registers
        \\ldr x2,  [%[restore], #0x00]
        \\mov sp, x2
        \\ldp x19, x20, [%[restore], #0x08]
        \\ldp x21, x22, [%[restore], #0x18]
        \\ldp x23, x24, [%[restore], #0x28]
        \\ldp x25, x26, [%[restore], #0x38]
        \\ldp x27, x28, [%[restore], #0x48]
        \\ldp x29, x30, [%[restore], #0x58]
        \\ret
        :
        : [save] "r" (save),
          [restore] "r" (restore),
        : .{ .x2 = true, .x3 = true, .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .x18 = true, .memory = true, .cc = true }
    );
}

fn makeContextAarch64(
    ctx: *Context,
    stack: []align(16) u8,
    func: *const fn (*anyopaque) void,
    arg: *anyopaque,
    on_exit: *const fn () callconv(.c) noreturn,
) void {
    const stack_top = @intFromPtr(stack.ptr) + stack.len;
    // aarch64 requires 16-byte aligned SP
    const aligned = stack_top & ~@as(usize, 15);

    ctx.sp = aligned;
    ctx.x29 = 0; // frame pointer
    ctx.x30 = @intFromPtr(&trampolineAarch64); // swapContext RETs here
    ctx.x19 = @intFromPtr(func);
    ctx.x20 = @intFromPtr(arg);
    ctx.x21 = @intFromPtr(on_exit);
    ctx.x22 = 0;
    ctx.x23 = 0;
    ctx.x24 = 0;
    ctx.x25 = 0;
    ctx.x26 = 0;
    ctx.x27 = 0;
    ctx.x28 = 0;
}

/// Trampoline: calls func(arg), then branches to on_exit().
/// x19 = func, x20 = arg, x21 = on_exit (all callee-saved).
/// Uses blr x19 to call func (sets lr = return address after blr).
/// After func returns, branches to on_exit via br x21.
fn trampolineAarch64() callconv(.naked) void {
    asm volatile (
        \\mov x0, x20
        \\blr x19
        \\br x21
    );
}
