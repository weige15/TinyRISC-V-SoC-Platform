"""Execute objdump's RV32 instruction words for cache coverage and counts.
This is a CPU-side control-flow check, NOT an RTL/board substitute.
Usage: python3 check_disasm.py before_hw_simd_mac.dis after_hw_simd_mac.dis
"""
import re, sys
from collections import Counter

def load(path):
    return {int(a,16): int(w,16) for a,w in
            re.findall(r'^([0-9a-f]+):\s+([0-9a-f]{8})\s',open(path).read(),re.M)}
def sx(v,n): return (v & ((1 << (n-1))-1)) - (v & (1 << (n-1)))

def run(code, n, p1=0x61000000, p2=0x62000000, preclean=False, cached=False):
    r=[0]*32; r[1]=0xfffffffc; r[2]=0x67000000
    r[10:14]=[p1,p2,0xffffff9a,n]
    mem={}; clean=[]; commands=[]; counts=Counter(); pc=min(code)
    # Addresses from the saved baseline ELF symbol annotations.
    symbols={}
    for line in open(sys.argv[1]):
        m=re.search(r'# ([0-9a-f]+) <([^>]+)>',line)
        if m: symbols[m[2]]=int(m[1],16)
    def put(fragment, vals):
        key=next(k for k in symbols if fragment in k)
        for i,v in enumerate(vals): mem[symbols[key]+4*i]=v
    put('g_clean_count',[2 if preclean else 0])
    put('g_clean_begin',[p1,p2]); put('g_clean_end',[p1+n,p2+n])
    put('g_set_length',[n if cached else 0]); put('g_set_offset',[154 if cached else 0])
    length=n if cached else 0
    for _ in range(100000):
        if pc==0xfffffffc: return counts,clean,commands
        w=code[pc]; op=w&127; rd=(w>>7)&31; f3=(w>>12)&7
        rs1=(w>>15)&31; rs2=(w>>20)&31; f7=w>>25
        nxt=pc+4; a=r[rs1]; b=r[rs2]; counts['instructions']+=1
        if op==0x13:
            imm=sx(w>>20,12)
            if f3==0: r[rd]=a+imm
            elif f3==7: r[rd]=a&imm
            else: raise AssertionError(hex(w))
        elif op==0x33:
            assert f3==0
            r[rd]=a-b if f7==32 else a+b
        elif op==0x17: r[rd]=pc+(w&0xfffff000)
        elif op==0x37: r[rd]=w&0xfffff000
        elif op==0x03:
            assert f3==2; counts['loads']+=1; r[rd]=mem.get((a+sx(w>>20,12))&0xffffffff,0)
        elif op==0x23:
            assert f3==2; counts['stores']+=1
            imm=sx(((w>>25)<<5)|((w>>7)&31),12); mem[(a+imm)&0xffffffff]=b
        elif op==0x63:
            imm=sx(((w>>31)<<12)|(((w>>7)&1)<<11)|(((w>>25)&63)<<5)|(((w>>8)&15)<<1),13)
            yes={0:a==b,1:a!=b,4:sx(a,32)<sx(b,32),5:sx(a,32)>=sx(b,32),6:a<b,7:a>=b}[f3]
            if yes: nxt=pc+imm
        elif op==0x6f:
            imm=sx(((w>>31)<<20)|(((w>>12)&255)<<12)|(((w>>20)&1)<<11)|(((w>>21)&1023)<<1),21)
            r[rd]=pc+4; nxt=pc+imm
        elif op==0x67:
            nxt=(a+sx(w>>20,12))&~1; r[rd]=pc+4
            if rd: counts['calls']+=1
        elif op==0x0f:
            if f3==2:
                assert w>>20==1; clean.append(a); counts['clean']+=1
            else: counts['fences']+=1
        elif op==0x0b:
            assert f3==4; commands.append((f7,a,b)); counts['custom']+=1
            if f7==0: length=a; r[rd]=a
            elif f7==1: r[rd]=0
            elif f7==2: r[rd]=0
            else: raise AssertionError(hex(w))
        else: raise AssertionError(hex(w))
        r=[x&0xffffffff for x in r]; r[0]=0; pc=nxt
    raise AssertionError('loop timeout')

before,after=map(load,sys.argv[1:])
print('Static instructions: before',len(before),'after',len(after))
for n in (0,3,300,1025):
    for label,code,pc,cache in [('before ordinary cold SET',before,False,False),('before ordinary warm SET',before,False,True),('before precleaned warm SET',before,True,True),('after ordinary',after,False,False)]:
        c,_,_=run(code,n,preclean=pc,cached=cache)
        print(n,label,dict(c))
cases=0
for n in (0,1,2,3,31,32,33,255,256,257,300,1023,1024,1025,2048,4097):
    for a in range(32):
        for b in range(32):
            p1=0x61000fe0+a; p2=0x62000fe0+b
            c,clean,cmd=run(after,n,p1,p2)
            want=[] if not n else list(range(p1&~31,p1+n,32))+list(range(p2&~31,p2+n,32))
            assert clean==want, (n,a,b,clean,want)
            assert not c['loads'] and not c['stores'] and not c['calls']
            assert len(cmd)==(2 if n else 0)
            if n: assert cmd==[(0,n,0xffffff9a),(1,p1,p2)]
            cases+=1
print('PASS:',cases,'binary coverage cases; exact line sequence for both buffers, two commands, no loads/stores/internal calls')
