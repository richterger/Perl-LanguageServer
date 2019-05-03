# Perl README

Language Server for Perl

## Features

* Syntax checking
* Symbols in file
* Symbols in workspace/directory
* Goto Definition
* Find References
* Run on remote syntax check on remote system via ssh
* Supports multiple workspace folders

## Requirements

You need to install the perl module Perl::LanguageServer to make this extention working,
e.g. run "cpan Perl::LanguageServer" on your target system.

Please make sure to always run the newest version of Perl::LanguageServer as well.

## Extension Settings


This extension contributes the following settings:

* `perl.enable`: enable/disable this extension
* `perl.sshAddr`: ip address of remote system
* `perl.sshUser`: user for ssh login
* `perl.sshCmd`: defaults to ssh on unix and plink on windows
* `perl.sshWorkspaceRoot`: path of the workspace root on remote system
* `perl.perlCmd`: defaults to perl
* `perl.sshArgs`: optional arguments for ssh
* `perl.pathMap`: mapping of local to remote paths
* `perl.perlInc`: array with paths to add to perl library path
* `perl.fileFilter`: array for filtering perl file, defaults to [*.pm,*.pl]
* `perl.ignoreDirs`: directories to ignore, defaults to [.vscode, .git, .svn]

## Remote check

If you developing on a remote machine, you can instruct the Perl::LanguageServer to
run on that remote machine, so the correct modules etc. are available for syntax check.
Do do so set sshAddr and sshUser, preferably in your workspace configuration.

Example:

    "sshAddr": "10.11.12.13",
    "sshUser": "root"

Also set sshWorkspaceRoot, so the local workspace path can be mapped to the remote one.

Example: if your local path is \\10.11.12.13\share\path\to\ws and on the remote machine you have /path/to/ws

    "sshWorkspaceRoot": "/path/to/ws"

The other possiblity is to provide a pathMap. This allows to have multiple mappings.

Example:

    "sshpathMap": [
        ['remote uri', 'local uri'],
        ['remote uri', 'local uri']
    ]

## Known Issues

Does not yet work on windows, due to issues with reading from stdin.

## Release Notes

see CHANGELOG.md
