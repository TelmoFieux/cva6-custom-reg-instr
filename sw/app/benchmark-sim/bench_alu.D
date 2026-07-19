
bench_alu.riscv:     file format elf32-littleriscv


Disassembly of section .text:

80000080 <main>:
80000080:	ff010113          	addi	sp,sp,-16
80000084:	b0002873          	csrr	a6,mcycle
80000088:	00000613          	li	a2,0
8000008c:	00012223          	sw	zero,4(sp)
80000090:	07b00593          	li	a1,123
80000094:	3e800513          	li	a0,1000
80000098:	00000693          	li	a3,0
8000009c:	3e800713          	li	a4,1000
800000a0:	00412783          	lw	a5,4(sp)
800000a4:	fff70713          	addi	a4,a4,-1
800000a8:	00f687b3          	add	a5,a3,a5
800000ac:	02b7e7b3          	rem	a5,a5,a1
800000b0:	00c686b3          	add	a3,a3,a2
800000b4:	00f12223          	sw	a5,4(sp)
800000b8:	fe0714e3          	bnez	a4,800000a0 <main+0x20>
800000bc:	00160613          	addi	a2,a2,1
800000c0:	fca61ce3          	bne	a2,a0,80000098 <main+0x18>
800000c4:	b0002773          	csrr	a4,mcycle
800000c8:	410706b3          	sub	a3,a4,a6
800000cc:	00d73633          	sltu	a2,a4,a3
800000d0:	411785b3          	sub	a1,a5,a7
800000d4:	00d12423          	sw	a3,8(sp)
800000d8:	40c587b3          	sub	a5,a1,a2
800000dc:	00f12623          	sw	a5,12(sp)
800000e0:	00000513          	li	a0,0
800000e4:	01010113          	addi	sp,sp,16
800000e8:	00008067          	ret

800000ec <heavy_computation>:
800000ec:	ff010113          	addi	sp,sp,-16
800000f0:	00012623          	sw	zero,12(sp)
800000f4:	00000613          	li	a2,0
800000f8:	07b00593          	li	a1,123
800000fc:	3e800513          	li	a0,1000
80000100:	00000693          	li	a3,0
80000104:	3e800713          	li	a4,1000
80000108:	00c12783          	lw	a5,12(sp)
8000010c:	fff70713          	addi	a4,a4,-1
80000110:	00f687b3          	add	a5,a3,a5
80000114:	02b7e7b3          	rem	a5,a5,a1
80000118:	00c686b3          	add	a3,a3,a2
8000011c:	00f12623          	sw	a5,12(sp)
80000120:	fe0714e3          	bnez	a4,80000108 <heavy_computation+0x1c>
80000124:	00160613          	addi	a2,a2,1
80000128:	fca61ce3          	bne	a2,a0,80000100 <heavy_computation+0x14>
8000012c:	01010113          	addi	sp,sp,16
80000130:	00008067          	ret

80000134 <_start>:
80000134:	80080137          	lui	sp,0x80080
80000138:	f49ff0ef          	jal	ra,80000080 <main>
8000013c:	0000006f          	j	8000013c <_start+0x8>
