# syscall_entry.s — naked SYSCALL/SYSRET entry trampoline (IA32_LSTAR).
#
# This MUST be hand-written assembly with NO function prologue. At entry
# the CPU has NOT switched stacks, so rsp is still the USER stack and we
# must capture it untouched. A Caustic `fn` emits `push rbp; mov rbp,rsp;
# push rbx; sub rsp,N` first — that runs on the user stack and shifts rsp
# (by 0x48 here) before we save it, so SYSRET hands the user a corrupted
# rsp and any return-address on its stack is read from the wrong slot.
# Register-only programs never noticed; a program that does call/ret
# across a syscall faulted. The IDT stubs are hand-asm for exactly this
# reason; the syscall entry now matches them.
#
# The dispatch LOGIC stays in Caustic (syscall.cst:dispatch). This stub
# only does the naked register/stack juggling, then `call`s it.
#
# CPU state at entry (after SYSCALL):
#   rcx = user RIP   r11 = user RFLAGS   rsp = USER rsp (unswitched)
#   rax = syscall nr   rdi rsi rdx r10 r8 r9 = args   IF cleared by FMASK
#
# Exotic instructions (gs override, sti/cli, sysretq) go in as raw bytes
# because caustic-as silently drops those mnemonics.

.section .text

.globl syscall_entry_asm
syscall_entry_asm:
    .byte 0x65, 0x48, 0x89, 0x24, 0x25, 0x88, 0x00, 0x00, 0x00   # mov gs:[0x88], rsp   (stash user rsp in the per-cpu shuttle, IRQs still off)
    .byte 0x65, 0x48, 0x8B, 0x24, 0x25, 0x90, 0x00, 0x00, 0x00   # mov rsp, gs:[0x90]   (kernel kstack)
    # Move the user rsp onto THIS thread's kstack immediately. gs:[0x88] is a
    # single per-cpu slot; once we `sti` below, a blocking syscall (wait/read)
    # can context-switch to another ring-3 thread whose own syscall overwrites
    # gs:[0x88]. Restoring rsp from it on the way out would then hand us a
    # foreign user rsp. The kstack is per-thread, so it survives the switch.
    .byte 0x65, 0xFF, 0x34, 0x25, 0x88, 0x00, 0x00, 0x00         # push qword gs:[0x88]   (user rsp -> per-thread kstack)
    push rcx          # user RIP   (sysretq restores it)
    push r11          # user RFLAGS
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    .byte 0xFB        # sti — safe now: on the kernel stack with a coherent frame
    push r9           # f -> 7th dispatch arg (on stack)
    mov r9, r8        # r9  <- e
    mov r8, r10       # r8  <- d
    mov rcx, rdx      # rcx <- c
    mov rdx, rsi      # rdx <- b
    mov rsi, rdi      # rsi <- a
    mov rdi, rax      # rdi <- nr
    call _kernel_syscall_cst_dispatch
    add rsp, 8        # drop pushed f
    .byte 0xFA        # cli — IRQs off across the unwind
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    pop r11           # user RFLAGS
    pop rcx           # user RIP
    .byte 0x5C        # pop rsp  — restore user rsp from the per-thread kstack (NOT shared gs:[0x88])
    .byte 0x48, 0x0F, 0x07   # sysretq

# uint64_t syscall_entry_addr_get(void) -> &syscall_entry_asm in rax.
# Lets syscall.cst load IA32_LSTAR with the trampoline's address without
# a cross-module fn_ptr (the symbol lives in this object).
.globl syscall_entry_addr_get
syscall_entry_addr_get:
    lea rax, [rip+syscall_entry_asm]
    ret
