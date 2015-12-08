HOWTO
=====

## prerequisite
- make kernel source available via /src/linux-dev
- install gcc, ruby, and numactl in your test system

## note
- this test tool has many page migration testcases, some of which are meaningful
  only on NUMA system. so please run this on NUMA system.

## run test
- do git-clone
- call "make test" as a root
- some detailed testcases (focused on race issues) are avaialble with
  "TEST_DEVEL=true make test"

## result
- after running, you can find the result line in stdout like below

    ...
    hugepage_migration_test:                        
    233 test(s) ran, 233 passed, 0 failed, 0 laters.

  the number of "failed" is supposed to be 0.

- If the test doesn't finish successfully (by kernel panic,) it's of
  cource problematic, so please let me know.

## Contact
- Naoya Horiguchi <n-horiguchi@ah.jp.nec.com>
