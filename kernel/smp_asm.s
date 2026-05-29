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
