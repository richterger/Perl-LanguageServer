# Perl::LanguageServer

Language Server and Debug Protocol Adapter for Perl

## Features

* Language Server

  * Syntax checking
  * Symbols in file
  * Symbols in workspace/directory
  * Goto Definition
  * Find References
  * Call Signatures
  * Supports multiple workspace folders
  * Document and selection formatting via perltidy
  * Run on remote system via ssh
  * Run inside docker container
  * Run inside kubernetes

* Debugger

  * Run, pause, step, next, return
  * Support for coro threads
  * Breakpoints
  * Conditional breakpoints
  * Breakpoints can be set while program runs and for modules not yet loaded
  * Variable view, can switch to every stack frame or coro thread
  * Set variable
  * Watch variable
  * Tooltips with variable values
  * Evaluate perl code in debuggee, in context of every stack frame of coro thread
  * Automatically reload changed Perl modules while debugging
  * Debug multiple perl programs at once
  * Run on remote system via ssh
  * Run inside docker container
  * Run inside kubernetes

## Requirements

You need to install the perl module Perl::LanguageServer to make this extension work,
e.g. run `cpan Perl::LanguageServer` on your target system.

Please make sure to always run the newest version of Perl::LanguageServer as well.

NOTE: Perl::LanguageServer depend on AnyEvent::AIO and Coro. There is a warning that
this might not work with newer Perls. It works fine for Perl::LanguageServer. So just
confirm the warning and install it.

Perl::LanguageServer depends on other Perl modules. It is a good idea to install most
of then with your linux package manager.

e.g. on Debian/Ubuntu run:

```

    sudo apt install libanyevent-perl libclass-refresh-perl libcompiler-lexer-perl \
    libdata-dump-perl libio-aio-perl libjson-perl libmoose-perl libpadwalker-perl \
    libscalar-list-utils-perl libcoro-perl

    sudo cpan Perl::LanguageServer

```

e.g. on Centos 7 run:

```

     sudo yum install perl-App-cpanminus perl-AnyEvent-AIO perl-Coro
     sudo cpanm Class::Refresh
     sudo cpanm Compiler::Lexer
     sudo cpanm Hash::SafeKeys
     sudo cpanm Perl::LanguageServer

```

In case any of the above packages are not available for your os version, just
leave them out. The cpan command will install missing dependencies. In case
the test fails, when running cpan `install`, you should try to run `force install`.

## Extension Settings

This extension contributes the following settings:

* `perl.enable`: enable/disable this extension
* `perl.sshAddr`: ip address of remote system
* `perl.sshPort`: optional, port for ssh to remote system
* `perl.sshUser`: user for ssh login
* `perl.sshCmd`: defaults to ssh on unix and plink on windows
* `perl.sshWorkspaceRoot`: path of the workspace root on remote system
* `perl.perlCmd`: defaults to perl
* `perl.perlArgs`: additional arguments passed to the perl interpreter that starts the LanguageServer
* `perl.sshArgs`: optional arguments for ssh
* `perl.pathMap`: mapping of local to remote paths
* `perl.perlInc`: array with paths to add to perl library path. This setting is used by the syntax checker and for the debuggee and also for the LanguageServer itself.
* `perl.fileFilter`: array for filtering perl file, defaults to [*.pm,*.pl]
* `perl.ignoreDirs`: directories to ignore, defaults to [.vscode, .git, .svn]
* `perl.debugAdapterPort`: port to use for connection between vscode and debug adapter inside Perl::LanguageServer.
* `perl.debugAdapterPortRange`: if debugAdapterPort is in use try ports from debugAdapterPort to debugAdapterPort + debugAdapterPortRange. Default 100.
* `perl.showLocalVars`: if true, show also local variables in symbol view
* `perl.logLevel`: Log level 0-2.
* `perl.logFile`: If set, log output is written to the given logfile, instead of displaying it in the vscode output pane. Log output is always appended. Only use during debugging of LanguageServer itself.
* `perl.disableCache`: If true, the LanguageServer will not cache the result of parsing source files on disk, so it can be used within readonly directories
* `perl.containerCmd`: If set Perl::LanguageServer can run inside a container. Options are: 'docker', 'docker-compose', 'kubectl'
* `perl.containerArgs`: arguments for containerCmd. Varies depending on containerCmd.
* `perl.containerMode`: To start a new container, set to 'run', to execute inside an existing container set to 'exec'. Note: kubectl only supports 'exec'
* `perl.containerName`: Image to start or container to exec inside or pod to use

## Debugger Settings for launch.json

* `type`: needs to be `perl`
* `request`: only `launch` is supported (this is a restriction of perl itself)
* `name`: name of this debug configuration
* `program`: path to perl program to start
* `stopOnEntry`: if true, program will stop on entry
* `args`:   optional, array with arguments for perl program
* `env`:    optional, object with environment settings
* `cwd`:    optional, change working directory before launching the debuggee
* `reloadModules`: if true, automatically reload changed Perl modules while debugging

## Remote syntax check & debugging

If you developing on a remote machine, you can instruct the Perl::LanguageServer to
run on that remote machine, so the correct modules etc. are available for syntax check and debugger is started on the remote machine.
To do so set sshAddr and sshUser, preferably in your workspace configuration.

Example:

```json
"sshAddr": "10.11.12.13",
"sshUser": "root"
```

Also set sshWorkspaceRoot, so the local workspace path can be mapped to the remote one.

Example: if your local path is \\10.11.12.13\share\path\to\ws and on the remote machine you have /path/to/ws

```json
"sshWorkspaceRoot": "/path/to/ws"
```

The other possibility is to provide a pathMap. This allows to having multiple mappings.

Examples:

```json
"sshpathMap": [
    ["remote uri", "local uri"],
    ["remote uri", "local uri"]
]

"perl.pathMap": [
    [
	"file:///",
	"file:///home/systems/mountpoint/"
    ]
]
```

## Syntax check & debugging inside a container

You can run the LanguageServer and/or debugger inside
a container by setting `containerCmd` and `conatinerName`.
There are more container options, see above.

.vscode/settings.json

```json
{
    "perl": {
        "enable": true,
        "containerCmd": "docker",
        "containerName": "perl_container",
    }
}
```



## FAQ

### Working directory is not defined

It is not defined what the current working directory is at the start of a perl program.
So Perl::LanguageServer makes no assumptions about it. To solve the problem you can set
the directory via cwd configuration parameter in launch.json for debugging.

### Module not found when debugging or during syntax check

If you reference a module with a relative path or if you assume that the current working directory
is part of the Perl search path, it will not work.
Instead set the perl include path to a fixed absolute path. In your settings.json do something like:

```
    "perl.perlInc": [
        "/path/a/lib",
        "/path/b/lib",
        "/path/c/lib",
    ],
```
Include path works for syntax check and inside of debugger.
`perl.perlInc` should be an absolute path.

### AnyEvent, Coro Warning during install

You need to install the AnyEvent::IO and Coro. Just ignore the warning that it might not work. For Perl::LanguageServer it works fine.

### 'richterger.perl' failed: options.port should be >= 0 and < 65536

Change port setting from string to integer

### Error "Can't locate MODULE_NAME"

Please make sure the path to the module is in `perl.perlInc` setting and use absolute path names in the perlInc settings
or make sure you are running in the expected directory by setting the `cwd` setting in the lauch.json.

### ERROR: Unknow perlmethod _rpcnot_setTraceNotification

This is not an issue, that just means that not all features of the debugging protocol are implemented.
Also it says ERROR, it's just a warning and you can safely ignore it.

### The debugger sometimes stops at random places

Upgrade to Version 2.4.0

### Message about Perl::LanguageServer has crashed 5 times

This is a problem when more than one instance of Perl::LanguageServer is running.
Upgrade to Version 2.4.0 solves this problem.

### Carton support

If you are using [Carton](https://metacpan.org/pod/Carton) to manage dependencies, add the full path to the Carton `lib` dir to your workspace settings file at `.vscode/settings.json`. For example:

#### Linux

```json
{
  "perl.perlInc": ["/home/myusername/projects/myprojectname/local/lib/perl5"]
}
```

#### Mac

```json
{
  "perl.perlInc": ["/Users/myusername/projects/myprojectname/local/lib/perl5"]
}
```

## Known Issues

Does not yet work on windows, due to issues with reading from stdin.
I wasn't able to find a reliable way to do a non-blocking read from stdin on windows.
I would be happy, if anyone knows how to do this in Perl.

Anyway, Perl::LanguageServer runs without problems inside of Windows Subsystem for Linux (WSL).

## Release Notes

see CHANGELOG.md

## More Info

- Presentation at German Perl Workshop 2020:

https://github.com/richterger/Perl-LanguageServer/blob/master/docs/Perl-LanguageServer%20und%20Debugger%20f%C3%BCr%20Visual%20Studio%20Code%20u.a.%20Editoren%20-%20Perl%20Workshop%202020.pdf

- Github: https://github.com/richterger/Perl-LanguageServer

- MetaCPAN: https://metacpan.org/release/Perl-LanguageServer

For reporting bugs please use GitHub issues.

## References

This is a Language Server and Debug Protocol Adapter for Perl

It implements the Language Server Protocol which provides
syntax-checking, symbol search, etc. Perl to various editors, for
example Visual Studio Code or Atom.

https://microsoft.github.io/language-server-protocol/specification

It also implements the Debug Adapter Protocol, which allows debugging
with various editors/includes

https://microsoft.github.io/debug-adapter-protocol/overview

To use both with Visual Studio Code, install the extension "perl"

https://marketplace.visualstudio.com/items?itemName=richterger.perl

Any comments and patches are welcome.

## LICENSE AND COPYRIGHT

Copyright 2018-2022 Gerald Richter.

This program is free software; you can redistribute it and/or modify it
under the terms of the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


