# MM regression kernel test tool

This test tool is intended to help kernel development and/or kernel testing related
to memory management subsystem (especially focusing on HWPOISON subsystem).

# Prerequisite

- `gcc`
- `ruby`
- `numactl`
- `numactl-devel` (on RHEL/Fedora), `libnuma-dev` (on Ubuntu)

Some testcase might require other libraries and tools (see individual test recipes).

If your system can not meet some of requirements, don't worry.  Testcases with
unmet requirements should be simply ignored.

# Simple usage

The following examples show typical usages of this test tool.
You need to run as `root` user.

If you'd like to simply run all defined testcases, run following commands:

```
$ git clone https://github.com/Naoya-Horiguchi/mm_regression
$ cd mm_regression
$ make
$ ./run.sh prepare debug
$ ./run.sh project run
```

Practically you might want to run specific set of testcases, then you can
do it by saving a list of testcases to be run to `work/debug/recipelist`.

```
$ make
$ ./run.sh prepare debug
$ ./run.sh recipe list | grep <string> > work/debug/recipelist
$ ./run.sh project run
```

Here `./run.sh recipe list` show the list of all testcases, so you can filter
by typical tools like `grep` and `sed`.

# Test tool internals

The following sections explain some concepts, settings and tips to understand
and management the test tool.  And they also help you run testing more flexibly.

## Test project (RUNNAME)

We first define "test project" as a single test execution set on a specific
environment.  It includes a set of test cases to be run, and information
about progress and/or result of the test result.  A test project is named
via environment variable `RUNNAME`, and all the information of the test project
is stored under `work/$RUNNAME`.

The above simple examples, `RUNNAME` is set to `debug`, so all data related
to this test project is stored under `work/debug/`.

### config file

The config file of a test project is located on `work/$RUNNAME/config`.
This file for example has the following settings:

```
$ cat work/debug/config
export RUNNAME=debug
export RUN_MODE=all
export SOFT_RETRY=1
export HARD_RETRY=1
export TEST_DESCRIPTION="MM regression test"
export UNPOISON=false
export FAILRETRY=
export PRIORITY=0-20
export BACKWARD_KEYWORD=
export FORWARD_KEYWORD=
export LOGLEVEL=1
```

This file is directly loaded when initializing test and affects how the
testing runs.
See "[Tips on running testing](#tips-on-running-testing)" section for
more details about each environment variables.

Some testcases can have their own control parameter, which can be added
in the project config file.
For example, some KVM-related testcases requires environment variable `VM`
to specify the testing virtual machine.

## Test case

A test case is associated with a single test recipe file which is located
under directory `cases` in hierarchial manner. The file path of the recipe
file is considered as "testcase ID". Some testcases are simliar, so they can
be generated from template recipe files whose file names have extension of
`.set3`.  Recipe files generated from template have extension of `.auto3`.
You can run `./run.sh recipe split` command to generate derived recipe files,
and you can see all recipe files with `./run.sh recipe list` command.

See section [Structure of test case](#structure-of-test-case) for details
about how to write testcases.

## Recipe list

When you create a test project with `./run.sh prepare` command,
a list of all testcases is stored on `work/$RUNNAME/full_recipe_list`.

When you start running testing, the test tool tries to determine which
testcases in `full_recipe_list` are executed based on environment variables
in the config file and system environment.
If you know that you are interested in only small subset of testcases,
you can manually construct `work/$RUNNAME/recipelist` by filtering testcases
(as done in the above simple example).

## Checking status of current testing

To know which is the current test project, run `./run.sh project show` command:

```
$ ./run.sh proj show
Project Name: debug
Total testcases: 531
Target testcases: 531
```

To show the status of the current test project, run `./run.sh project summary` command:

```
$ ./run.sh proj summary
Project Name: debug
Progress: 394 / 525 (75%)
PASS 350, FAIL 26, WARN 0, SKIP 18, NONE 131
```

You can show per-testcase detailed summary, set `-p` option.

```
$ ./run.sh proj summary -p
Project Name: 220506a
PASS mm/compaction
FAIL mm/hugetlb/deferred_dissolve/error-type-hard-offline_dissolve-dequeue.auto3
PASS mm/hugetlb/deferred_dissolve/error-type-hard-offline_dissolve-free.auto3
FAIL mm/hugetlb/deferred_dissolve/error-type-soft-offline.auto3
SKIP mm/hugetlb/deferred_dissolve_fault.auto3
PASS mm/hugetlb/dissolve_failure
PASS mm/hugetlb/per_process_usage_counter
...
Progress: 394 / 525 (75%)
```

## Restarting and resuming

When you cease the current testing or the testing system restart during
testing, you can restart from the aborted testcases by simply running
`./run.sh project run` commnad.

If you restart all testcases from the beginning of test case list,
you can set `-a` option to `./run.sh project run` command.
Sometimes you want to avoid already passed testcases, then add
both of `-a` option and `-p` option.

If a testcase caused kernel panic, then restart from the next testcase
of the aborted testcase, you can set `-w` option.

## Tips on running testing

There're other control parameters on testing, all of which are specified via
environment variables.

- `RUN_MODE`: each test case has at least one test type (specified by
  `TEST_TYPE` or default type `normal`).  This variable is used to determine
  whether a testcase is executed or not.  If `TEST_TYPE` of a testcase is
  included in `RUN_MODE`, the testcase should be executed.
  Otherwise, the testcases is skipped.
    - `RUN_MODE=all` is a special value.  With this value, all testcases are
      executed regardless of test types.
    - `RUN_MODE` can have multiple values (comma-separated). Then, testcase
      is determined to run when all types in `TEST_TYPE` is included in
      `RUN_MODE`.
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
- `LOGLEVEL`: controlling log level (default: 1). If you set this 2 (0),
  more (less) log messages will be printed out.

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
- `TRDIR`: root directory of this test tool.
- `TCDIR`: directory path of test_core module (`TCDIR=$TRDIR/test_core`).
- `TDIR`: temporary directory used by individual testcases (`TDIR=$TRDIR/tmp`).
- `WDIR`: directory path to save information about result/progress of
  the test projects (`WDIR=$TRDIR/work`).
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
- `TEST_TYPE`: this variable is used to give the testcase some keywords for
  its purpose (for example, to show that it's still under development).
  You can set multiple keywords to this variable with comma-separated string.
  If `TEST_TYPE` is set to the string other than default one (`normal`),
  the testcase will be skipped by default. If you like to run it, you need to
  set environment variable `RUN_MODE` to one of the keywords in `TEST_TYPE`.
  You can see the list of `TEST_TYPE` of all testcases by running
  `make recipe_priority` command.

### Other tips

- If you try to run all testcases, it's recommended to enable some reboot
  mechanism on kernel panic, for example like giving kernel boot parameter
  `panic=N` or enabling kdump settings.

# Contact

- Naoya Horiguchi <naoya.horiguchi@nec.com> / <nao.horiguchi@gmail.com>
