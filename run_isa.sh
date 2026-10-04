#!/bin/bash
# run_isa.sh — à lancer depuis la racine du repo
# usage : ./run_isa.sh dual     (ou single)

CFG=${1:-default}
ISA=tmp/riscv-tests/isa
BIN2MEM="python3 sw/utils/bin2mem.py"     # <- mets la même commande que pour ton test manuel
OUT=$PWD/tmp/isa_mem
LOG=$PWD/isa_logs_$CFG
SUM=$PWD/isa_summary_$CFG.txt

mkdir -p $OUT $LOG; : > $SUM

make build > $LOG/build.log 2>&1 || { echo "build KO, voir $LOG/build.log"; exit 1; }

for t in $(cat rv32-isa.list); do
  rm -f $OUT/$t.bin $OUT/$t.mem
  riscv64-unknown-elf-objcopy -O binary $ISA/$t $OUT/$t.bin
  $BIN2MEM $OUT/$t.bin
  if [ ! -f $OUT/$t.mem ]; then echo "NOMEM $t" | tee -a $SUM; continue; fi

  th=$(riscv64-unknown-elf-nm $ISA/$t | awk '/ tohost$/{print $1}')

  timeout 600 make sim APP=$t APP_PATH=$OUT batch-mode=1 tohost_addr=$th > $LOG/$t.log 2>&1

  if   grep -q "ISA PASS" $LOG/$t.log; then r=PASS
  elif grep -q "ISA FAIL" $LOG/$t.log; then r="FAIL($(grep -o 'sous-test [0-9]*' $LOG/$t.log | head -1))"
  else r=TIMEOUT; fi
  echo "$r $t" | tee -a $SUM
done

echo "[$CFG] PASS: $(grep -c ^PASS $SUM) / $(wc -l < rv32-isa.list)"
grep -v ^PASS $SUM
