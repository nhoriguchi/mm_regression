# MM regression kernel test tool

## Prerequisite

- `gcc`, `ruby`, and `numactl` must be available on your test system.

## Simple usage

The following commands run all testcases in foreground process:

```
$ git clone https://github.com/Naoya-Horiguchi/mm_regression
$ cd mm_regression
$ make
$ bash run.sh
```

You need to run with `root` user.  Practically you might want to run specific
set of testcases or other testing environment to help your kernel development.
The following sections explain some concepts, settings and tips to run test
more flexibly.

## Test project (RUNNAME)

We first define "test project" as a single test execution set on a specific
environment.  It includes a set of test cases to be run, and information
about progress and/or result of the test result.  A test project is named
via environment variable `RUNNAME`, and all the information of the test project
is stored under `work/$RUNNAME`.

## Test case

A test case is associated with a single test recipe file which is located
under directory `cases` in hierarchial manner. The file path of the recipe
file is considered as "testcase ID". Some testcases are simliar, so they can
be generated from template recipe files whose file names have extension of
`.set3`.  Recipe files generated from template have extension of `.auto3`.
You can run `make split_recipes` command to generate derived recipe files,
and you can see all recipe files with `make allrecipes` command.

## Recipe list

By default, a test project includes all test cases in its run list.  It
takes long to run all test cases, so you can choose to run only subset of
test cases for practical purpose. If you prepare `work/$RUNNAME` with `make
prepare` command, then the full list of test cases are stored in
`work/$RUNNAME/full_recipe_list`, so one easy way to create a run list is to
grep on this file. Typical operations are like below:

```
$ export RUNNAME=testrun
$ make prepare
$ grep <keyword> work/$RUNNAME/full_recipe_list > work/$RUNNAME/recipelist
$ bash run.sh
```

If you know the recipe file which you want to run, you can pass it to
`run.sh` as an argument:
~~~
$ bash run.sh cases/mm/compaction
~~~

## Show summary

The progress/result of a test project is stored under `work/$RUNNAME`, but it's
not easy to see from it how the test going. To show the summary or progress,
we provide script `test_core/lib/test_summary.rb`.

```
$ ruby test_core/lib/test_summary.rb work/testrun/
Progress: 428 / 455 (94%)
PASS 307, FAIL 29, WARN 4, SKIP 88, NONE 27

$ ruby test_core/lib/test_summary.rb -C work/testrun/
PASS 20200814/102319 [10] cases/mm/thp/swap
FAIL 20200814/102351 [10] cases/mm/thp/anonymous/split_retry_thp-base.auto3
FAIL 20200814/102431 [10] cases/mm/thp/anonymous/split_retry_thp-double_mapping.auto3
PASS 20200814/102441 [10] cases/mm/thp/anonymous/split_retry_thp-pmd_split.auto3
...
Progress: 428 / 455 (94%)
Target: work/testrun
```

As shown in this example, `-C` option shows detailed (per test case) summary.

## Running mode (BACKGROUND)

Some test case might reboot the system. From the viewpoint of test
automation, you might want to make sure that testing complete with system
reboot. Background mode, which can be enabled by environment variable
`BACKGROUND=true`, is helpful for that purpose.

When you set `BACKGROUND=true`, `run.sh` returns immediately with
registering systemd service `test.service` and testing is done under systemd
process.  Even if the testing system reboots during testing, systemd
restarts the test service and continues from the test case that was being
executed on the reboot event.

```
BACKGROUND=true bash run.sh
```

## Tips on running testing

There're other control parameters on testing, all of which are specified via
environment variables.

- `AGAIN`: when using this test tool for debugging purpose, you might need to
  run a test case multiple times on the same environment. A test project saves
  its running status under `work/$RUNNAME`, and by default completed test cases
  are skipped on subsequent call of `run.sh`. So in order to rerun the test case,
  you need to give `AGAIN=true` as environment variable:
  ```
  AGAIN=true bash run.sh
  ```
- `LOGLEVEL`: controlling log level (default: 1). If you set this 2 (0),
  more (less) log messages will be printed out.
- `SOFT_RETRY`: default is 3. You consider a test case as passed when
  the test case passed once until it failed `SOFT_RETRY` times.
- `HARD_RETRY`: default is 1. You consider a test case as passed when the
  test case passed `HARD_RETRY` times in a row. If you set both `SOFT_RETRY`
  and `HARD_RETRY` to more than 1, a test case is considered as passed when
  it passed `HARD_RETRY` times in a row until it failed `SOFT_RETRY` times.
- `PRIORITY`: each test case has its own priority, which is a number from 0
  to 20 and smaller value means higher priority. This environment variable
  is used to limit the test cases to be run based on priority. You can specify
  this parameter like `PRIORITY=0-10,12,15-18`. The default is `0-10`.
- `RUN_MODE`: some test cases are not planned to be maintained for long and
  just used for one-time debugging. Such test cases should not be run on
  default testing, so you need to  give `RUN_MODE=devel` to run them.
- `BACKWARD_KEYWORD`: the expected behavior of a test case might depend on
  the version of kernel or some other components. Such test cases define
  the keyword to switch the expected behavior to choose old one and new one.
  In the policy of this test tool, the default expected behavior of each
  test case is the behavior of the upstream kernel, but if you want to test
  the older kernel, you can include the keyword into this environment variable
  to adjust the expectation of your test project.
- `FORWARD_KEYWORD`: similar to `BACKWARD_KEYWORD`, this variable switches
  the expected behavior of affected test cases. This variable are used to
  make test cases for developing feature (not merged upstream yet) pass.
  This environment variable is only helpful in development phase.

# For developers

This section explains how this test tool works for test developers.

## Structure of test case

One test case is associated with one recipe file. A recipe file is a bash
script.  Each recipe file has any testcase specific variables and the
following four functions which are called by test harness processes:
- `_prepare()`: this function is called to check preconditions or execute
  testcase specific preparations. If the system doesn't meet the required
  preconditions or succeeded the preparations, this function should return
  non-zero. Then the test logic (`_control()`) will not be executed.
- `_control()`: decribes main logic of the test case.
- `_cleanup()`: if there's some side-effect by `_prepare()`, this function
  is to clean it up.
- `_check()`: this fucntion can include some post check code, called after
  `_cleanup()`.

A test case does not always require all of these 4 function to be defined.
Simple test case may only include `_control()`. Assertion is done by string
based return code, which is checked to be equal to string specified by
`EXPECTED_RETURN_CODE`. If a test case have definition of this variable,
return code is checked in `_check()` phase. See the following example:
```
EXPECTED_RETURN_CODE="START CHECK1 END"

_control() {
    set_return_code START
    test_logic
    if [ $? -eq 0 ] ; then
        set_return_code CHECK1
    fi
    ...
    set_return_code END
}
```
in this case, return code check passes only when you enter the
if-block (so maybe `test_logic()` succeeded). Defining return code
as string (array) is helpful to understand/manage expected behaviors.

## Workflow

When you run this test tool by `run.sh`, it runs the testcases listed in
`work/$RUNNAME/recipelist` one-by-one from the top. The hierarchy in recipe
files under `cases` is important because each test cases and each directory
is executed in separate sub-process.  This prevents that some variables
defined in a testcase affect the behavior of other testcases.

For example, think about the recipe hierarchy like below:
```
cases/test1
cases/dir1/test2
cases/dir1/dir2/test3
cases/dir1/test4
cases/test5
```
Then, whole testing workflow is like below:
```
main thread
  |---> sub thread
  |     run cases/test1
  |---> sub thread
  |     (source cases/dir1/config)
  |       |---> sub thread
  |       |     run cases/dir1/test2
  |       |---> sub thread
  |       |     (source cases/dir1/dir2/config)
  |       |       |---> sub thread
  |       |       |     run cases/dir1/dir2/test3
  |       |     (dir_cleanup() in cases/dir1/dir2/config)
  |       |---> sub thread
  |       |     run cases/dir1/test4
  |      (dir_cleanup() in cases/dir1/config)
  |---> sub thread
  |     run cases/test5
  *
```
Not only each testcase is run in a separate sub-process, but also a
sub-process is created when entering subdirectory. This will be helpful to
define "directory-wide" environment variables. If you put a file named
`config` and define environment variables there, they are inherited to all
testcases under the directory (including subdirectories).  `config` file
could also include `_prepare()` function and `dir_cleanup()`, which are called
"just after entering to the directory" or "just before exiting from the
directory", respectively.

## Tips

### Per-testcase variables

The following variables are defined and available in each testcase:
- `GTMPD`: set to the path of the root directory of the test project
  (`work/$RUNNAME`), where some metadata files are stored to control the
  test project.
- `RTMPD`: set to the path of the testcase currently running. For example,
  if you are running testcase `cases/dir1/test2`, then `RTMPD` is set to
  `RTMPD=work/$RUNNAME/dir1/test2`.
- `TMPD`: set to the path of the directory storing information per-testcase,
  separating to subdirectories depending on the "retry round". For example,
  if current "retry round" is 2nd soft retry and 3rd hard retry, `TMPD` is
  set to `$RTMPD/2-3`.  Any raw data stored in test logic should be stored
  under this directory.

The following variables are defined in each testcase and used to affect
the test harness's behavior:
- `MAX_REBOOT`: in some reboot-aware testcases, this variable is set to a
  positive integer to limit the maximum times of system reboots. The default
  value is 0.
- `TEST_PRIORITY`: this variable specifies the priority of the testcase.
  The default is 10. It's used to skip and/or order testcases to be run from
  user via environment variable `PRIORITY` (defined above).
- `TEST_TYPE`: defines test type of the testcase.

### Other tips

- If you try to run all testcases, it's recommended to enable some reboot
  mechanism on kernel panic, for example like giving kernel boot parameter
  `panic=N` or enabling kdump settings.

# Contact

- Naoya Horiguchi <naoya.horiguchi@nec.com> / <nao.horiguchi@gmail.com>
