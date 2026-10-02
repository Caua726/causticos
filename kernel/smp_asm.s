# smp_asm.s — SMP primitives, every "exotic" instruction emitted as
# raw bytes because caustic-as silently drops mnemonics it doesn't
# recognise (wrmsr, rdmsr, cli, sti, mfence, lock prefix, segment
# override, xadd, test/jz, etc.). Output bytes are annotated next to
# each `.byte` line with the equivalent Intel mnemonic so future
# maintainers can recognise them.
#
# ABI: SysV AMD64 — args in rdi, rsi, rdx, rcx, r8, r9; return in rax.

.section .text

# void smp_wrmsr(uint32_t msr /*edi*/, uint64_t value /*rsi*/)
.globl smp_wrmsr
smp_wrmsr:
    mov     ecx, edi
    mov     rax, rsi
    mov     rdx, rsi
    .byte   0x48, 0xC1, 0xEA, 0x20        # shr rdx, 32
    .byte   0x0F, 0x30                    # wrmsr
    ret

# void smp_rdmsr_into(uint32_t msr /*edi*/, uint64_t *out /*rsi*/)
.globl smp_rdmsr_into
smp_rdmsr_into:
    mov     ecx, edi
    .byte   0x0F, 0x32                    # rdmsr
    .byte   0x48, 0xC1, 0xE2, 0x20        # shl rdx, 32
    .byte   0x48, 0x09, 0xD0              # or rax, rdx
    .byte   0x48, 0x89, 0x06              # mov [rsi], rax
    ret

# void smp_read_gs_self_into(uint64_t *out /*rdi*/)
.globl smp_read_gs_self_into
smp_read_gs_self_into:
    .byte   0x65, 0x48, 0x8B, 0x04, 0x25, 0x00, 0x00, 0x00, 0x00   # mov rax, QWORD PTR gs:[0]
    .byte   0x48, 0x89, 0x07              # mov [rdi], rax
    ret

# void smp_fetch_add_ticket_into(uint64_t *p /*rdi*/, uint64_t *out /*rsi*/)
# Atomically increments the upper 32 bits by 1, stores previous value in *out.
.globl smp_fetch_add_ticket_into
smp_fetch_add_ticket_into:
    mov     rax, 0x100000000
    .byte   0xF0, 0x48, 0x0F, 0xC1, 0x07  # lock xadd QWORD PTR [rdi], rax
    .byte   0x48, 0x89, 0x06              # mov [rsi], rax
    ret

# void smp_inc_serving(uint64_t *p /*rdi*/)
.globl smp_inc_serving
smp_inc_serving:
    .byte   0xF0, 0x83, 0x07, 0x01        # lock add DWORD PTR [rdi], 1
    ret

# void smp_atomic_add_into(int64_t *p /*rdi*/, int64_t delta /*rsi*/, int64_t *out /*rdx*/)
# Atomically adds delta to *p, stores the PREVIOUS value of *p in *out.
# (lock xadd leaves the old value in the source register, here rsi.)
.globl smp_atomic_add_into
smp_atomic_add_into:
    .byte   0xF0, 0x48, 0x0F, 0xC1, 0x37  # lock xadd QWORD PTR [rdi], rsi
    .byte   0x48, 0x89, 0x32              # mov [rdx], rsi
    ret

# void smp_save_cli_into(uint64_t *out /*rdi*/)
.globl smp_save_cli_into
smp_save_cli_into:
    .byte   0x9C                          # pushfq
    .byte   0x8F, 0x07                    # pop QWORD PTR [rdi]
    .byte   0xFA                          # cli
    ret

# void smp_restore(uint64_t flags /*rdi*/)
.globl smp_restore
smp_restore:
    .byte   0x48, 0xF7, 0xC7, 0x00, 0x02, 0x00, 0x00   # test rdi, 0x200
    .byte   0x74, 0x01                    # jz +1
    .byte   0xFB                          # sti
    ret

.globl smp_mfence
smp_mfence:
    .byte   0x0F, 0xAE, 0xF0              # mfence
    ret

.globl smp_pause
smp_pause:
    .byte   0xF3, 0x90                    # pause (rep nop)
    ret

# void smp_load_cr3(uint64_t pml4_phys /*rdi*/)
.globl smp_load_cr3
smp_load_cr3:
    .byte   0x0F, 0x22, 0xDF              # mov cr3, rdi
    ret

# uint64_t smp_read_cr3(void) -> current CR3
.globl smp_read_cr3
smp_read_cr3:
    .byte   0x0F, 0x20, 0xD8              # mov rax, cr3
    ret

# void smp_read_cr3_into(uint64_t *out /*rdi*/) -> *out = CR3
# Output-pointer form so the value lands in a caller stack local (per-cpu by
# nature) instead of a shared module global — two cpus reading CR3 at once then
# never corrupt each other (the old cr3_val shuttle could load the wrong CR3).
.globl smp_read_cr3_into
smp_read_cr3_into:
    .byte   0x0F, 0x20, 0xD8              # mov rax, cr3
    .byte   0x48, 0x89, 0x07              # mov [rdi], rax
    ret

# void smp_read_cr2_into(uint64_t *out /*rdi*/) -> *out = CR2 (faulting addr)
.globl smp_read_cr2_into
smp_read_cr2_into:
    .byte   0x0F, 0x20, 0xD0              # mov rax, cr2
    .byte   0x48, 0x89, 0x07              # mov [rdi], rax
    ret

# void smp_call_ptr(uint64_t target /*rdi*/)
# Calls target via a register indirection — keeps the function pointer
# in a register that doesn't survive a preempt/resume in any corrupted
# way (rdi/rax are caller-saved but both get pushed+popped by the IRQ
# stub so preemption restores them). Used by the thread entry
# trampoline to jump to a new thread's entry without relying on a
# module-level shuttle variable which would race between cpus.
.globl smp_call_ptr
smp_call_ptr:
    mov     rax, rdi
    call    rax
    ret

# uint64_t smp_in_irq_context(void)
# Reads gs:[0x70] → smp.PerCpu.in_irq_context for the current cpu.
# Lets modules that can't `use "smp.cst"` (e.g. pmm.cst — smp already
# depends on pmm) observe the per-cpu IRQ-context flag without
# closing a module cycle.
.globl smp_in_irq_context
smp_in_irq_context:
    .byte   0x65, 0x48, 0x8B, 0x04, 0x25, 0x70, 0x00, 0x00, 0x00   # mov rax, QWORD PTR gs:[0x70]
    ret

# Per-cpu preempt count (smp.PerCpu.preempt_count, gs:[0x78]). One
# instruction each, so an interrupt can never split the read-modify-write;
# no lock prefix, because only this cpu ever touches its own slot.
.globl smp_preempt_inc
smp_preempt_inc:
    .byte   0x65, 0x48, 0xFF, 0x04, 0x25, 0x78, 0x00, 0x00, 0x00   # inc QWORD PTR gs:[0x78]
    ret

.globl smp_preempt_dec
smp_preempt_dec:
    .byte   0x65, 0x48, 0xFF, 0x0C, 0x25, 0x78, 0x00, 0x00, 0x00   # dec QWORD PTR gs:[0x78]
    ret

# void smp_gs_load_into(uint64_t off /*rdi*/, uint64_t *out /*rsi*/)
# *out = QWORD PTR gs:[off] — a per-cpu field read for modules that cannot
# import smp.cst (lock.cst sits below it).
.globl smp_gs_load_into
smp_gs_load_into:
    .byte   0x65, 0x48, 0x8B, 0x07        # mov rax, QWORD PTR gs:[rdi]
    .byte   0x48, 0x89, 0x06              # mov [rsi], rax
    ret

# void smp_rflags_into(uint64_t *out /*rdi*/) — *out = RFLAGS, IF untouched.
.globl smp_rflags_into
smp_rflags_into:
    .byte   0x9C                          # pushfq
    .byte   0x8F, 0x07                    # pop QWORD PTR [rdi]
    ret

# void smp_run_on_stack(uint64_t top /*rdi*/, uint64_t entry /*rsi*/) — never returns.
# Switch to the stack whose top is `top`, enable interrupts and call `entry`,
# abandoning the current stack. lifecycle.user_fault uses it to leave the
# per-cpu IST stack an exception arrived on before doing anything that sleeps.
.globl smp_run_on_stack
smp_run_on_stack:
    mov     rsp, rdi
    .byte   0x48, 0x31, 0xED              # xor rbp, rbp (end of the frame chain)
    mov     rax, rsi
    .byte   0xFB                          # sti
    call    rax
.Lrun_on_stack_hang:
    .byte   0xF4                          # hlt — entry never returns
    jmp     .Lrun_on_stack_hang

# void smp_enter_user(uint64_t rip /*rdi*/, uint64_t rsp /*rsi*/, uint64_t arg /*rdx*/)
# Never returns: iretq into ring 3 at rip with stack rsp and rdi = arg, every
# other general register zeroed (no kernel pointer may leak into user state).
# Built from registers only. The previous spelling passed rip/rsp/rdi through
# module globals, and two cpus starting user threads at once — or one thread
# preempted between the stores and the loads — could hand a thread another
# thread's entry point and stack.
.globl smp_enter_user
smp_enter_user:
    .byte   0xFA                          # cli — iretq restores IF from the frame
    mov     rax, 0x23
    push    rax                           # SS  = USER_DS_SEL
    push    rsi                           # RSP (user)
    mov     rax, 0x202
    push    rax                           # RFLAGS = IF | reserved bit 1
    mov     rax, 0x2B
    push    rax                           # CS  = USER_CS64_SEL
    push    rdi                           # RIP (user)
    mov     rdi, rdx                      # the thread's argument (0 for a main thread)
    .byte   0x48, 0x31, 0xDB              # xor rbx, rbx
    .byte   0x48, 0x31, 0xC9              # xor rcx, rcx
    .byte   0x48, 0x31, 0xD2              # xor rdx, rdx
    .byte   0x48, 0x31, 0xF6              # xor rsi, rsi
    .byte   0x48, 0x31, 0xED              # xor rbp, rbp
    .byte   0x4D, 0x31, 0xC0              # xor r8, r8
    .byte   0x4D, 0x31, 0xC9              # xor r9, r9
    .byte   0x4D, 0x31, 0xD2              # xor r10, r10
    .byte   0x4D, 0x31, 0xDB              # xor r11, r11
    .byte   0x4D, 0x31, 0xE4              # xor r12, r12
    .byte   0x4D, 0x31, 0xED              # xor r13, r13
    .byte   0x4D, 0x31, 0xF6              # xor r14, r14
    .byte   0x4D, 0x31, 0xFF              # xor r15, r15
    .byte   0x48, 0x31, 0xC0              # xor rax, rax
    .byte   0x48, 0xCF                    # iretq
