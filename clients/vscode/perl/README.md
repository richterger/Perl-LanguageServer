# Perl README

Language Server and Debugger for Perl

## Features

* Language Server
  * Syntax checking
  * Symbols in file
  * Symbols in workspace/directory
  * Goto Definition
  * Find References
  * Call Signatures
  * Supports multiple workspace folders
  * Run on remote system via ssh
* Debugger
  * Run, pause, step, next, return
  * Support for coro threads
  * Breakpoints 
  * Conditional breakpoints
  * Breakpoints can be set while programm runs and for modules not yet loaded
  * Variable view, can switch to every stack frame or coro thread
  * Set variable
  * Watch variable
  * Tooltips with variable values
  * Evaluate perl code in debuggee, in context of every stack frame of coro thread
  * Automatically reload changed Perl modules while debugging
  * Debug mutiple perl programm at once
  * Run on remote system via ssh


## Requirements

You need to install the perl module Perl::LanguageServer to make this extention working,
e.g. run "cpan Perl::LanguageServer" on your target system.

Please make sure to always run the newest version of Perl::LanguageServer as well.

## Extension Settings


This extension contributes the following settings:

* `perl.enable`: enable/disable this extension
* `perl.sshAddr`: ip address of remote system
* `perl.sshPort`: optional, port for ssh to remote system
* `perl.sshUser`: user for ssh login
* `perl.sshCmd`: defaults to ssh on unix and plink on windows
* `perl.sshWorkspaceRoot`: path of the workspace root on remote system
* `perl.perlCmd`: defaults to perl
* `perl.perlArgs`: arguments passed to the perl interpreter that starts the LanguageServer
* `perl.sshArgs`: optional arguments for ssh
* `perl.pathMap`: mapping of local to remote paths
* `perl.perlInc`: array with paths to add to perl library path.  This setting is used by the syntax checker, the parser and for the debugee. It is NOT used to find the LanguageServer itself (use perlArgs : [ \"-I/incpath\"] for non default path of LanguageServer)
* `perl.fileFilter`: array for filtering perl file, defaults to [*.pm,*.pl]
* `perl.ignoreDirs`: directories to ignore, defaults to [.vscode, .git, .svn]
* `perl.debugAdapterPort`: port to use for connection between vscode and debug adapter inside Perl::LanguageServer. On a multi user system every user must use a differnt port.
* `perl.showLocalVars`: if true, show also local variables in symbol view
* `perl.logLevel`: Log level 0-2.
* `perl.disableCache`: if true, the LanguageServer will not cache the result of parsing source files on disk, so it can be used within readonly directories"

## Debugger Settings for launch.json

* `type`: needs to be `perl`
* `request`: only `launch` is supported (this is a restriction of perl itself)
* `name`: name of this debug configuration
* `program`: path to perl program to start
* `stopOnEntry`: if true, program will stop on entry
* `args`:   optional, array with arguments for perl program
* `env`:    optional, object with environment settings 
* `cwd`:    optional, change working directory before launching the debugee
* `reloadModules`: if true, automatically reload changed Perl modules while debugging

## Remote syntax check & debugging

If you developing on a remote machine, you can instruct the Perl::LanguageServer to
run on that remote machine, so the correct modules etc. are available for syntax check and debugger is startet on the remote machine.
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

The other possiblity is to provide a pathMap. This allows to have multiple mappings.

Examples:

```json
"sshpathMap": [
    ['remote uri', 'local uri'],
    ['remote uri', 'local uri']
]

"perl.pathMap": [
    [
	"file:///",
	"file:///home/systems/mountpoint/"
    ]
]
```

## Syntax check & debugging inside a conatiner

It's possible to use the ssh settings also for containers. The example below is for docker-compose but there's nothing prevent you from tuning it to do docker exec, kubectl exec, machinectl shell or whatnot.

.vscode/settings.json

```json
{
    "perl": {
        "enable": true,
        "sshAddr": "dummy",
        "sshUser": "dummy",
        "sshCmd": "bin/shell-into-appserver.sh",
        "sshWorkspaceRoot": "/home/code (directory in the container)",
        "logLevel": 0,
    }
}
```

bin/shell-into-appserver.sh:

```bash
#!/usr/bin/env bash
COMMAND=$(echo "$@" | sed 's/^.*perl /perl /')
docker-compose exec -u "$UID" -T [SERVICE NAME] $COMMAND
```

## Known Issues

Does not yet work on windows, due to issues with reading from stdin.

## Release Notes

see CHANGELOG.md

## More Info

Presentation on German Perl Workshop 2020:

https://github.com/richterger/Perl-LanguageServer/blob/master/docs/Perl-LanguageServer%20und%20Debugger%20f%C3%BCr%20Visual%20Studio%20Code%20u.a.%20Editoren%20-%20Perl%20Workshop%202020.pdf
