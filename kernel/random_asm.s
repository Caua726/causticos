# random_asm.s — CPU entropy and identification primitives.
#
# Same discipline as smp_asm.s: caustic-as silently DROPS mnemonics it does
# not recognise, so anything exotic is emitted as raw bytes with the Intel
# mnemonic in the comment beside it. A dropped instruction here would not
# fail to build — it would produce a random number generator that returns
# whatever was in rax, which is exactly the kind of silence this file exists
# to avoid.
#
# These live in a .s rather than inline asm because cpuid clobbers all four
# of eax/ebx/ecx/edx, and rbx is callee-saved: doing that inside a Caustic
# function would corrupt whatever the compiler had parked there.
#
# ABI: SysV AMD64 — args in rdi, rsi, rdx, rcx, r8, r9; return in rax.

.section .text

# void random_cpuid_into(uint32_t leaf /*edi*/, uint32_t subleaf /*esi*/,
#                        uint64_t *out /*rdx*/)
# Writes out[0..3] = eax, ebx, ecx, edx. A 32-bit write zeroes the upper half
# of the destination register, so storing the full 64-bit register yields the
# zero-extended value with no masking needed.
.globl random_cpuid_into
random_cpuid_into:
    .byte   0x53                          # push rbx   (callee-saved; cpuid clobbers it)
    .byte   0x49, 0x89, 0xD0              # mov r8, rdx  (cpuid clobbers rdx)
    .byte   0x89, 0xF8                    # mov eax, edi
    .byte   0x89, 0xF1                    # mov ecx, esi
    .byte   0x0F, 0xA2                    # cpuid
    .byte   0x49, 0x89, 0x00              # mov [r8], rax
    .byte   0x49, 0x89, 0x58, 0x08        # mov [r8+8], rbx
    .byte   0x49, 0x89, 0x48, 0x10        # mov [r8+16], rcx
    .byte   0x49, 0x89, 0x50, 0x18        # mov [r8+24], rdx
    .byte   0x5B                          # pop rbx
    ret

# void random_rdseed_into(uint64_t *out /*rdi*/, uint64_t *ok /*rsi*/)
# RDSEED draws from the raw entropy source behind the DRBG, so it is the
# right primitive for seeding. It legitimately fails when the pool is
# momentarily drained — the carry flag reports that, and the caller retries.
# *ok = 1 on success, 0 on failure.
#
# Both results come back through pointers rather than rax: the Caustic wrapper
# has a prologue, and a function whose value is "whatever the call left in rax"
# is one the compiler is entitled to overwrite. Same shape as smp_asm.s.
.globl random_rdseed_into
random_rdseed_into:
    .byte   0x48, 0x0F, 0xC7, 0xF8        # rdseed rax
    .byte   0x48, 0x89, 0x07              # mov [rdi], rax   (MOV leaves flags alone)
    .byte   0x0F, 0x92, 0xC0              # setc al
    .byte   0x0F, 0xB6, 0xC0              # movzx eax, al
    .byte   0x48, 0x89, 0x06              # mov [rsi], rax
    ret

# void random_rdrand_into(uint64_t *out /*rdi*/, uint64_t *ok /*rsi*/)
# The hardware DRBG. Cheaper and far less likely to fail than RDSEED, and
# still a NIST SP 800-90A generator — the fallback when RDSEED is absent or
# starved. *ok = 1 on success, 0 on failure.
.globl random_rdrand_into
random_rdrand_into:
    .byte   0x48, 0x0F, 0xC7, 0xF0        # rdrand rax
    .byte   0x48, 0x89, 0x07              # mov [rdi], rax
    .byte   0x0F, 0x92, 0xC0              # setc al
    .byte   0x0F, 0xB6, 0xC0              # movzx eax, al
    .byte   0x48, 0x89, 0x06              # mov [rsi], rax
    ret

# void random_rdtsc_into(uint64_t *out /*rdi*/)
# The timestamp counter. Not entropy by itself, but the low bits of the
# interval between unrelated events (an interrupt, a disk completion) carry
# some, which is what the jitter pool collects when no TRNG exists.
.globl random_rdtsc_into
random_rdtsc_into:
    .byte   0x0F, 0x31                    # rdtsc            (edx:eax)
    .byte   0x48, 0xC1, 0xE2, 0x20        # shl rdx, 32
    .byte   0x48, 0x09, 0xD0              # or rax, rdx
    .byte   0x48, 0x89, 0x07              # mov [rdi], rax
    ret
