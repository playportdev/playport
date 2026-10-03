# i386 instructions with guest memory accesses, one per line (Intel syntax,
# assembled with llvm-mc). window_coverage_audit.py translates each one in
# 32-bit mode and requires every access to address the guest window.
# Plain loads and stores, every address form
mov eax, dword ptr [ebx]
mov dword ptr [ebx], eax
mov eax, dword ptr [ebx - 16]
mov dword ptr [ebx + 0x12345], eax
mov eax, dword ptr [ebx + esi*4 - 16]
mov dword ptr [ebx + esi*8 + 0x7ffffff0], eax
mov eax, dword ptr [esi*2]
mov eax, dword ptr [0x7ffe0300]
mov dword ptr [0x00c5e000], eax
mov eax, dword ptr fs:[0x18]
mov dword ptr fs:[eax], ecx
mov al, byte ptr [ebx]
mov byte ptr [ebx], al
mov ax, word ptr [ebx]
mov word ptr [ebx], ax
mov dword ptr [ebx], 0x12345678
movzx eax, byte ptr [ebp - 4]
movsx eax, word ptr [esp + 8]
mov eax, dword ptr [esp + 4]
mov dword ptr [esp], eax
mov eax, dword ptr [ebp + 8]
mov eax, dword ptr [bx + si - 16]
xlatb
# Read-modify-write and ALU forms
add dword ptr [ebx], eax
add eax, dword ptr [ebx + 4]
or byte ptr [ebx], 1
inc dword ptr [ebx]
dec word ptr [ebx]
neg dword ptr [ebx]
not dword ptr [ebx]
shl dword ptr [ebx], 3
shld dword ptr [ebx], eax, 4
cmp dword ptr [ebx], 0
test byte ptr [ebx], 1
imul eax, dword ptr [ebx]
div dword ptr [ebx]
cmovne eax, dword ptr [ebx]
bt dword ptr [ebx], eax
bts dword ptr [ebx], 5
btr dword ptr [ebx], eax
btc dword ptr [ebx], eax
setne byte ptr [ebx]
xchg dword ptr [ebx], eax
# Locked atomics
lock add dword ptr [ebx], eax
lock adc dword ptr [ebx], eax
lock sbb dword ptr [ebx], eax
lock sub dword ptr [ebx], 1
lock and dword ptr [ebx], eax
lock or dword ptr [ebx], eax
lock xor dword ptr [ebx], eax
lock inc dword ptr [ebx]
lock dec dword ptr [ebx]
lock neg dword ptr [ebx]
lock not dword ptr [ebx]
lock xadd dword ptr [ebx], eax
lock cmpxchg dword ptr [ebx], ecx
lock cmpxchg8b qword ptr [esi]
lock bts dword ptr [ebx], eax
lock btr dword ptr [ebx], eax
lock btc dword ptr [ebx], eax
lock xadd word ptr [ebx], ax
# Stack
push eax
push 0x12345678
push dword ptr [ebx]
push word ptr [ebx]
pop eax
pop dword ptr [ebx]
pop esp
pushal
popal
pushfd
popfd
.byte 0xe8, 0xfb, 0x00, 0x00, 0x00  # call rel32
call eax
call dword ptr [ebx + 8]
call dword ptr [0x00401000]
ret
ret 8
jmp dword ptr [ebx]
leave
enter 16, 0
enter 16, 2
push fs
pop fs
# Far transfers through memory
jmp fword ptr [ebx]
call fword ptr [ebx]
# String operations
movsb
movsd
rep movsb
rep movsd
stosb
stosd
rep stosd
lodsd
cmpsb
repe cmpsb
scasb
repne scasb
movsd es:[edi], dword ptr fs:[esi]
# x87
fld dword ptr [ebx]
fld qword ptr [ebx]
fld tbyte ptr [ebx]
fst dword ptr [ebx]
fstp qword ptr [ebx]
fstp tbyte ptr [ebx]
fild dword ptr [ebx]
fild qword ptr [ebx]
fistp dword ptr [ebx]
fisttp qword ptr [ebx]
fadd dword ptr [ebx]
fmul qword ptr [ebx]
fcomp dword ptr [ebx]
fnstcw word ptr [ebx]
fldcw word ptr [ebx]
fnstsw word ptr [ebx]
fnstenv [ebx]
fldenv [ebx]
fnsave [ebx]
frstor [ebx]
fbld tbyte ptr [ebx]
fbstp tbyte ptr [ebx]
# MMX and SSE
movq mm0, qword ptr [ebx]
movq qword ptr [ebx], mm0
movd mm0, dword ptr [ebx]
movaps xmm0, xmmword ptr [ebx]
movaps xmmword ptr [ebx], xmm0
movups xmm0, xmmword ptr [ebx + 4]
movups xmmword ptr [ebx + esi*4], xmm0
movss xmm0, dword ptr [ebx]
movss dword ptr [ebx], xmm0
movsd xmm0, qword ptr [ebx]
movsd qword ptr [ebx], xmm0
movq xmm0, qword ptr [ebx]
movq qword ptr [ebx], xmm0
movd xmm0, dword ptr [ebx]
movd dword ptr [ebx], xmm0
movhps xmm0, qword ptr [ebx]
movhps qword ptr [ebx], xmm0
movlps xmm0, qword ptr [ebx]
movlps qword ptr [ebx], xmm0
movhpd xmm0, qword ptr [ebx]
movlpd xmm0, qword ptr [ebx]
pinsrw xmm0, word ptr [ebx], 3
pinsrb xmm0, byte ptr [ebx], 3
pinsrd xmm0, dword ptr [ebx], 1
pextrb byte ptr [ebx], xmm0, 3
pextrw word ptr [ebx], xmm0, 3
extractps dword ptr [ebx], xmm0, 1
insertps xmm0, dword ptr [ebx], 0x10
addps xmm0, xmmword ptr [ebx]
mulss xmm0, dword ptr [ebx]
cvtsi2ss xmm0, dword ptr [ebx]
cvttss2si eax, dword ptr [ebx]
pshufd xmm0, xmmword ptr [ebx], 0x1b
movdqa xmm0, xmmword ptr [ebx]
movdqu xmmword ptr [ebx], xmm0
movntdq xmmword ptr [ebx], xmm0
movntps xmmword ptr [ebx], xmm0
movnti dword ptr [ebx], eax
movntdqa xmm0, xmmword ptr [ebx]
movntq qword ptr [ebx], mm0
maskmovq mm0, mm1
maskmovdqu xmm0, xmm1
movddup xmm0, qword ptr [ebx]
lddqu xmm0, xmmword ptr [ebx]
ldmxcsr dword ptr [ebx]
stmxcsr dword ptr [ebx]
fxsave [ebx]
fxrstor [ebx]
# Cache and prefetch
prefetcht0 byte ptr [ebx]
prefetchnta byte ptr [ebx]
clflush byte ptr [ebx]
# Descriptor tables
sgdt [ebx]
sidt [ebx]
