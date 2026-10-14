
/home/kuotzuwei15/NNchip/TinyRISC-V-SoC-Platform/Platform/sw/results/offset9/lab2_api_rv32.o:     file format elf32-littleriscv


Disassembly of section .text.hw_simd_mac_assume_clean_begin:

00000000 <hw_simd_mac_assume_clean_begin>:
   0:	0330000f          	fence	rw,rw
   4:	00058e63          	beqz	a1,20 <.L2>
			4: R_RISCV_BRANCH	.L2
   8:	00b505b3          	add	a1,a0,a1
   c:	fe057513          	andi	a0,a0,-32
  10:	00b57863          	bgeu	a0,a1,20 <.L2>
			10: R_RISCV_BRANCH	.L2

00000014 <.L3>:
  14:	0015200f          	.insn	4, 0x0015200f
  18:	02050513          	addi	a0,a0,32
  1c:	feb56ce3          	bltu	a0,a1,14 <.L3>
			1c: R_RISCV_BRANCH	.L3

00000020 <.L2>:
  20:	00068e63          	beqz	a3,3c <.L4>
			20: R_RISCV_BRANCH	.L4
  24:	00d606b3          	add	a3,a2,a3
  28:	fe067613          	andi	a2,a2,-32
  2c:	00d67863          	bgeu	a2,a3,3c <.L4>
			2c: R_RISCV_BRANCH	.L4

00000030 <.L5>:
  30:	0016200f          	.insn	4, 0x0016200f
  34:	02060613          	addi	a2,a2,32
  38:	fed66ce3          	bltu	a2,a3,30 <.L5>
			38: R_RISCV_BRANCH	.L5

0000003c <.L4>:
  3c:	0330000f          	fence	rw,rw
  40:	00008067          	ret

Disassembly of section .text.hw_simd_mac_assume_clean_end:

00000000 <hw_simd_mac_assume_clean_end>:
   0:	00008067          	ret

Disassembly of section .text.hw_simd_mac_reuse_arm:

00000000 <hw_simd_mac_reuse_arm>:
   0:	00100793          	li	a5,1
   4:	00000713          	li	a4,0
   8:	08e7c78b          	.insn	4, 0x08e7c78b
   c:	00008067          	ret

Disassembly of section .text.hw_simd_mac_reuse_disarm:

00000000 <hw_simd_mac_reuse_disarm>:
   0:	00000793          	li	a5,0
   4:	06f7c78b          	.insn	4, 0x06f7c78b
   8:	00008067          	ret

Disassembly of section .text._Z16hw_simd_mac_convPaS_lmb:

00000000 <hw_simd_mac_conv(signed char*, signed char*, long, unsigned long, bool)>:
   0:	04068663          	beqz	a3,4c <.L25>
			0: R_RISCV_BRANCH	.L25
   4:	02071e63          	bnez	a4,40 <.L20>
			4: R_RISCV_BRANCH	.L20
   8:	0330000f          	fence	rw,rw
   c:	00d50733          	add	a4,a0,a3
  10:	fe057793          	andi	a5,a0,-32
  14:	00e7f863          	bgeu	a5,a4,24 <.L24>
			14: R_RISCV_BRANCH	.L24

00000018 <.L21>:
  18:	0017a00f          	.insn	4, 0x0017a00f
  1c:	02078793          	addi	a5,a5,32
  20:	fee7ece3          	bltu	a5,a4,18 <.L21>
			20: R_RISCV_BRANCH	.L21

00000024 <.L24>:
  24:	00d58733          	add	a4,a1,a3
  28:	fe05f793          	andi	a5,a1,-32
  2c:	00e7f863          	bgeu	a5,a4,3c <.L23>
			2c: R_RISCV_BRANCH	.L23

00000030 <.L22>:
  30:	0017a00f          	.insn	4, 0x0017a00f
  34:	02078793          	addi	a5,a5,32
  38:	fee7ece3          	bltu	a5,a4,30 <.L22>
			38: R_RISCV_BRANCH	.L22

0000003c <.L23>:
  3c:	0330000f          	fence	rw,rw

00000040 <.L20>:
  40:	0ac6c68b          	.insn	4, 0x0ac6c68b
  44:	02b5450b          	.insn	4, 0x02b5450b
  48:	00008067          	ret

0000004c <.L25>:
  4c:	00000513          	li	a0,0
  50:	00008067          	ret

Disassembly of section .text.hw_simd_mac:

00000000 <hw_simd_mac>:
   0:	04068463          	beqz	a3,48 <.L36>
			0: R_RISCV_BRANCH	.L36
   4:	0330000f          	fence	rw,rw
   8:	00d50733          	add	a4,a0,a3
   c:	fe057793          	andi	a5,a0,-32
  10:	00e7f863          	bgeu	a5,a4,20 <.L32>
			10: R_RISCV_BRANCH	.L32

00000014 <.L33>:
  14:	0017a00f          	.insn	4, 0x0017a00f
  18:	02078793          	addi	a5,a5,32
  1c:	fee7ece3          	bltu	a5,a4,14 <.L33>
			1c: R_RISCV_BRANCH	.L33

00000020 <.L32>:
  20:	00d58733          	add	a4,a1,a3
  24:	fe05f793          	andi	a5,a1,-32
  28:	00e7f863          	bgeu	a5,a4,38 <.L34>
			28: R_RISCV_BRANCH	.L34

0000002c <.L35>:
  2c:	0017a00f          	.insn	4, 0x0017a00f
  30:	02078793          	addi	a5,a5,32
  34:	fee7ece3          	bltu	a5,a4,2c <.L35>
			34: R_RISCV_BRANCH	.L35

00000038 <.L34>:
  38:	0330000f          	fence	rw,rw
  3c:	00c6c68b          	.insn	4, 0x00c6c68b
  40:	02b5450b          	.insn	4, 0x02b5450b
  44:	00008067          	ret

00000048 <.L36>:
  48:	00000513          	li	a0,0
  4c:	00008067          	ret
