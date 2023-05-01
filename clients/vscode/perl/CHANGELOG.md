# Change Log

## 2.6.0   not yet released

- Add debug setting for running as different user. See sudoUser setting. (#174) [wielandp]
- Allow to use a string for debuggee arguments. (#149, #173) [wielandp]
- Add stdin redirection (#166) [wielandp]
- Add link to issues to META files (#168) [szabgab/issues]
- Add support for podman
- Add support for run Perl::LanguageServer outside, but debugger inside a container
- Fix: Spelling (#170, #171) [pkg-perl-tools]
- Fix: Convert charset encoding of debugger output according to current locale (#167) [wielandp]


## 2.5.0   `2023-02-05`

- Set minimal Perl version to 5.16 (#91)
- Per default environment from vscode will be passed to debuggee, syntax check and perltidy.
- Add configuration `disablePassEnv` to not pass environment variables.
- Support for `logLevel` and `logFile` settings via LanguageServer protocol and
not only via command line options (#97) [schellj]
- Fix: "No DB::DB routine defined" (#91) [peterdragon]
- Fix: Typos and spelling in README (#159) [dseynhae]
- Fix: Update call to gensym(), to fix 'strict subs' error (#164) [KohaAloha]
- Convert identention from tabs to spaces and remove trailing whitespaces 

## 2.4.0   `2022-11-18`

- Choose a different port for debugAdapterPort if it is already in use. This
  avoids trouble with starting `Perl::LanguageServer` if another instance
  of `Perl::LanguageServer` is running on the same machine (thanks to hakonhagland)
- Add configuration `debugAdapterPortRange`, for choosing range of port for dynamic
  port assignment
- Add support for using LanguageServer and debugger inside a Container.
  Currently docker containers und containers running inside kubernetes are supported.
- When starting debugger session and `stopOnEntry` is false, do not switch to sourefile
  where debugger would stop, when `stopOnEntry` is true.
- Added some FAQs in README

- Fix: Debugger stopps at random locations
- Fix: debugAdapterPort is now numeric
- Fix: debugging loop with each statement (#107)
- Fix: display of arrays in variables pane on mac (#120)
- Fix: encoding for `perltidy` (#127)
- Fix: return error if `perltidy` fails, so text is not removed by failing
  formatting request (#87)
- Fix: FindBin does not work when checking syntax (#16)

## 2.3.0   `2021-09-26`

- Arguments section in Variable lists now `@ARGV` and `@_` during debugging (#105)
- `@_` is now correctly evaluated inside of debugger console
- `$#foo` is now correctly evaluated inside of debugger console
- Default debug configuration is now automatically provided without
    the need to create a `launch.json` first (#103)
- Add Option `cacheDir` to specify location of cache dir (#113)
- Fix: Debugger outputted invalid thread reference causes "no such coroutine" message,
    so watchs and code from the debug console is not expanded properly
- Fix: LanguageServer hangs when multiple request send at once from VSCode to LanguageServer
- Fix: cwd parameter for debugger in launch.json had no effect (#99)
- Fix: Correctly handle paths with drive letters on windows
- Fix: sshArgs parameter was not declared as array (#109)
- Disable syntax check on windows, because it blocks the whole process when running on windows,
    until handling of child's processes is fixed
- Fixed spelling (#86,#96,#101) [chrstphrchvz,davorg,aluaces]

## 2.2.0    `2021-02-21`
- Parser now supports Moose method modifieres before, after and around,
  so they can be used in symbol view and within reference search
- Support Format Document and Format Selection via perltidy
- Add logFile config option
- Add perlArgs config option to pass options to Perl interpreter. Add some documentation for config options.
- Add disableCache config option to make LanguageServer usable with readonly directories.
- updated dependencies package.json & package-lock.json
- Fix deep recursion in SymbolView/Parser which was caused by function prototypes.
  Solves also #65
- Fix duplicate req id's that caused cleanup of still
  running threads which in turn caused the LanguageServer to hang
- Prevent dereferencing an undefined value (#63) [Heiko Jansen]
- Fix datatype of cwd config options (#47)
- Use perlInc setting also for LanguageServer itself (based only pull request #54 from ALANVF)
- Catch Exceptions during display of variables inside debugger
- Fix detecting duplicate LanguageServer processes
- Fix spelling in documentation (#56) [Christopher Chavez]
- Remove notice about Compiler::Lexer 0.22 bugs (#55) [Christopher Chavez]
- README: Typo and grammar fixes. Add Carton lib path instructions. (#40) [szTheory]
- README: Markdown code block formatting (#42) [szTheory]
- Makefile.PL: add META_MERGE with GitHub info (#32) [Christopher Chavez]
- search.cpan.org retired, replace with metacpan.org (#31) [Christopher Chavez]

## 2.1.0    `2020-06-27`
- Improve Symbol Parser (fix parsing of anonymous subs)
- showLocalSymbols
- function names in breadcrump
- Signature Help for function/method arguments
- Add Presentation on Perl Workshop 2020 to repos
- Remove Compiler::Lexer from distribution since
    version is available on CPAN
- Make stdout unbuffered while debugging
- Make debugger use perlInc setting
- Fix fileFilter setting
- Sort Arrays numerically in variables view of debugger
- Use rootUri if workspaceFolders not given
- Fix env config setting
- Recongnice changes in config of perlCmd

## 2.0.2    `2020-01-22`
- Plugin: Fix command line parameters for plink
- Perl::LanguageServer: Fix handling of multiple parallel request, improve symlink handling, add support for UNC paths in path mapping, improve logging for logLevel = 1

## 2.0.1    `2020-01-14`
Added support for reloading Perl module while debugging, make log level configurable, make sure tooltips don't call functions

## 2.0.0    `2020-01-01`
Added Perl debugger

## 0.9.0   `2019-05-03`
Fix issues in the Perl part, make sure to update Perl::LanguageServer from cpan

## 0.0.3   `2018-09-08`
Fix issue with not reading enough from stdin, which caused LanguageServer to hang sometimes

## 0.0.2  `2018-07-21`
Fix quitting issue when starting Perl::LanguageServer, more fixes are in the Perl part

## 0.0.1  `2018-07-13`
Initial Version


