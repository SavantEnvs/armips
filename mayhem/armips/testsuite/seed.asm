.n64
.create "/tmp/out.bin",0

.definelabel value,0x10007FFF

start:
	li		a0,0x123456
	li		a0,-0x123456
	li		a0,0xFFFFF123
	lui		a1,0x1234
	addiu	a1,a1,0x5678
	lw		a0,0x7FF0
	sw		a1,0x7FF0
	beq		a0,a1,start
	nop
	jr		ra
	nop

.close
