
test_edge_case.riscv:     file format elf32-littleriscv


Disassembly of section .text:

80000000 <_start>:
80000000:	00a00293          	li	t0,10
80000004:	00528333          	add	t1,t0,t0
80000008:	405303b3          	sub	t2,t1,t0
8000000c:	02638e33          	mul	t3,t2,t1
80000010:	025e0eb3          	mul	t4,t3,t0
80000014:	00500e93          	li	t4,5
80000018:	005e8f33          	add	t5,t4,t0
8000001c:	005f0fb3          	add	t6,t5,t0
80000020:	06300f13          	li	t5,99
80000024:	00100293          	li	t0,1
80000028:	00001437          	lui	s0,0x1
8000002c:	11140413          	addi	s0,s0,273 # 1111 <_start-0x7fffeeef>
80000030:	000024b7          	lui	s1,0x2
80000034:	22248493          	addi	s1,s1,546 # 2222 <_start-0x7fffddde>
80000038:	00528c63          	beq	t0,t0,80000050 <branch_taken>
8000003c:	00001437          	lui	s0,0x1
80000040:	bad40413          	addi	s0,s0,-1107 # bad <_start-0x7ffff453>
80000044:	0000c4b7          	lui	s1,0xc
80000048:	ad248493          	addi	s1,s1,-1326 # bad2 <_start-0x7fff452e>
8000004c:	009402b3          	add	t0,s0,s1

80000050 <branch_taken>:
80000050:	00040933          	add	s2,s0,zero
80000054:	00000517          	auipc	a0,0x0
80000058:	02c50513          	addi	a0,a0,44 # 80000080 <__DATA_BEGIN__>
8000005c:	000052b7          	lui	t0,0x5
80000060:	5aa28293          	addi	t0,t0,1450 # 55aa <_start-0x7fffaa56>
80000064:	00552023          	sw	t0,0(a0)
80000068:	00052303          	lw	t1,0(a0)
8000006c:	00100293          	li	t0,1
80000070:	00528463          	beq	t0,t0,80000078 <skip_exception>
80000074:	00002383          	lw	t2,0(zero) # 0 <_start-0x80000000>

80000078 <skip_exception>:
80000078:	00100193          	li	gp,1

8000007c <end_loop>:
8000007c:	0000006f          	j	8000007c <end_loop>
