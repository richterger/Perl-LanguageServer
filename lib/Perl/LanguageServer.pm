package Perl::LanguageServer;

use v5.16;

use strict ;
use Moose ;
use Moose::Util qw( apply_all_roles );

use Coro ;
use Coro::AIO ;
use Coro::Handle ;
use AnyEvent;
use AnyEvent::Socket ;
use JSON ;
use Data::Dump qw{dump pp} ;
use IO::Select ;

use Perl::LanguageServer::Req ;
use Perl::LanguageServer::Workspace ;

with 'Perl::LanguageServer::Methods' ;
with 'Perl::LanguageServer::IO' ;

no warnings 'uninitialized' ;

=head1 NAME

Perl::LanguageServer - Language Server and Debug Protocol Adapter for Perl

=head1 VERSION

Version 2.5.0

=cut

our $VERSION = '2.6.1';


=head1 SYNOPSIS

This is a Language Server and Debug Protocol Adapter for Perl

It implements the Language Server Protocol which provides
syntax-checking, symbol search, etc. Perl to various editors, for
example Visual Studio Code or Atom.

L<https://microsoft.github.io/language-server-protocol/specification>

It also implements the Debug Adapter Protocol, which allow debugging
with various editors/includes

L<https://microsoft.github.io/debug-adapter-protocol/overview>

Should work with any Editor/IDE that support the Language-Server-Protocol.

To use both with Visual Studio Code, install the extension "perl"

Any comments and patches are welcome.

=cut

our $json = JSON -> new -> utf8(1) -> ascii(1) ;
our $jsonpretty = JSON -> new -> utf8(1) -> ascii(1) -> pretty (1) ;

our %running_reqs ;
our %running_coros ;
our $exit ;
our $workspace ;
our $dev_tool ;
our $debug1 = 0 ;
our $debug2 = 0 ;
our $log_file ;
our $client_version ;
our $reqseq = 1_000_000_000 ;


has 'channel' =>
    (
    is => 'ro',
    isa => 'Coro::Channel',
    default => sub { Coro::Channel -> new }
    ) ;

has 'debug' =>
    (
    is => 'rw',
    isa => 'Int',
    default => 1,
    ) ;

has 'listen_port' =>
    (
    is => 'rw',
    isa => 'Maybe[Int]',
    ) ;

has 'roles' =>
    (
    is => 'rw',
    isa => 'HashRef',
    default => sub { {} },
    ) ;

has 'out_semaphore' =>
    (
    is => 'ro',
    isa => 'Coro::Semaphore',
    default => sub { Coro::Semaphore -> new }
    ) ;

has 'log_prefix' =>
    (
    is => 'rw',
    isa => 'Str',
    default => 'LS',
    ) ;

has 'log_req_txt' =>
    (
    is => 'rw',
    isa => 'Str',
    default => '---> Request: ',
    ) ;

# ---------------------------------------------------------------------------

sub logger
    {
    my $self = shift ;
    my $src ;
    if (!defined ($_[0]) || ref ($_[0]))
        {
        $src = shift ;
        }
    $src = $self if (!$src) ;

    if ($log_file)
        {
        open my $fh, '>>', $log_file or warn "$log_file : $!" ;
        print $fh $src?$src -> log_prefix . ': ':'', @_ ;
        close $fh ;
        }
    else
        {
        print STDERR $src?$src -> log_prefix . ': ':'', @_ ;
        }
    }


# ---------------------------------------------------------------------------

sub send_notification
    {
    my ($self, $notification, $src, $txt) = @_ ;

    $txt ||= "<--- Notification: " ;
    $notification -> {jsonrpc} = '2.0' ;
    my $outdata = $json -> encode ($notification) ;
    my $guard = $self -> out_semaphore -> guard  ;
    use bytes ;
    my $len  = length($outdata) ;
    my $wrdata = "Content-Length: $len\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n$outdata" ;
    $self -> _write ($wrdata) ;
    if ($debug1)
        {
        $wrdata =~ s/\r//g ;
        $self -> logger ($src, $txt, $jsonpretty -> encode ($notification), "\n") if ($debug1) ;
        }
    }

# ---------------------------------------------------------------------------

sub call_method
    {
    my ($self, $reqdata, $req, $id) = @_ ;

    my $method = $req -> is_dap?$reqdata -> {command}:$reqdata -> {method} ;
    my $module ;
    my $name ;

    if ($method =~ /^(\w+)\/(\w+)$/)
        {
        $module = $1 ;
        $name   = $2 ;
        }
    elsif ($method =~ /^(\w+)$/)
        {
        $name   = $1 ;
        }
    elsif ($method =~ /^\$\/(\w+)$/)
        {
        $name   = $1 ;
        }
    else
        {
        die "Unknown method $method" ;
        }
    $module = $req -> type eq 'dbgint'?'DebugAdapterInterface':'DebugAdapter' if ($req -> is_dap) ;

    my $base_package = __PACKAGE__ . '::Methods' ;
    my $package = $base_package ;
    $package .= '::' . $module if ($module) ;

    my $fn = $package . '.pm' ;
    $fn =~ s/::/\//g ;
    if (!exists $INC{$fn} || !exists $self -> roles -> {$fn})
        {
        #$self -> logger (dump (\%INC), "\n") ;
        $self -> logger ("apply_all_roles ($self, $package, $fn)\n") ;
        apply_all_roles ($self, $package) ;
        $self -> roles -> {$fn} = 1 ;
        }

    my $perlmethod ;
    if ($req -> is_dap)
        {
        $perlmethod = '_dapreq_' . $name ;
        }
    else
        {
        $perlmethod = (defined($id)?'_rpcreq_':'_rpcnot_') . $name ;
        }
    $self -> logger ("method=$perlmethod\n") if ($debug1) ;
    die "Unknown perlmethod $perlmethod" if (!$self -> can ($perlmethod)) ;

no strict ;
    return $self -> $perlmethod ($workspace, $req) ;
use strict ;
    }

# ---------------------------------------------------------------------------

sub process_req
    {
    my ($self, $id, $reqdata) = @_ ;

    my $xid = $id ;
    $xid ||= $reqseq++ ;
    $running_coros{$xid} = async
        {
        my $req_guard = Guard::guard
            {
            $self -> logger ("done handle_req id=$xid\n") if ($debug1) ;
            delete $running_reqs{$xid} ;
            delete $running_coros{$xid} ;
            };

        my $type   = $reqdata -> {type} ;
        my $is_dap = $type?1:0 ;
        $type      = defined ($id)?'request':'notification' if (!$type) ;
        $self -> logger ("handle_req id=$id\n") if ($debug1) ;
        my $req = Perl::LanguageServer::Req  -> new ({ id => $id, is_dap => $is_dap, type => $type, params => $is_dap?$reqdata -> {arguments} || {}:$reqdata -> {params} || {}}) ;
        $running_reqs{$xid} = $req ;

        my $rsp ;
        my $outdata ;
        my $outjson ;
        eval
            {
            $rsp = $self -> call_method ($reqdata, $req, $id) ;
            $id = undef if (!$rsp) ;
            if ($req -> is_dap)
                {
                $outjson = { request_seq => -$id, seq => -$id, command => $reqdata -> {command}, success => JSON::true, type => 'response', $rsp?(body => $rsp):()}  ;
                }
            else
                {
                $outjson = { id => $id, jsonrpc => '2.0', result => $rsp}  if ($rsp) ;
                }
            $outdata = $json -> encode ($outjson) if ($outjson) ;
            } ;
        if ($@)
            {
            $self -> logger ("ERROR: $@\n") ;
            if ($req -> is_dap)
                {
                $outjson = { request_seq => -$id, command => $reqdata -> {command}, success => JSON::false, message => "$@", , type => 'response'} ;
                }
            else
                {
                $outjson = { id => $id, jsonrpc => '2.0', error => { code => -32001, message => "$@" }} ;
                }
            $outdata = $json -> encode ($outjson) if ($outjson) ;
            }

        if (defined($id))
            {
            my $guard = $self -> out_semaphore -> guard  ;
            use bytes ;
            my $len  = length ($outdata) ;
            my $wrdata = "Content-Length: $len\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n$outdata" ;
            my $sum = 0 ;
            my $cnt ;
            while ($sum < length ($wrdata))
                {
                $cnt = $self -> _write ($wrdata, undef, $sum) ;
                die "write_error ($!)" if ($cnt <= 0) ;
                $sum += $cnt ;
                }

            if ($debug1)
                {
                $wrdata =~ s/\r//g ;
                $self -> logger ("<--- Response: ", $jsonpretty -> encode ($outjson), "\n") ;
                }
            }
        } ;
    }

# ---------------------------------------------------------------------------

sub mainloop
    {
    my ($self) = @_ ;

    my $buffer = '' ;
    while (!$exit)
        {
        use bytes ;
        my %header ;
        my $line ;
        my $cnt ;
        my $loop ;
        header:
        while (1)
            {
            $self -> logger ("start aio read, buffer len = " . length ($buffer) . "\n")  if ($debug2) ;
            if ($loop)
                {
                $cnt = $self -> _read (\$buffer, 8192, length ($buffer), undef, 1) ;
                $self -> logger ("end aio read cnt=$cnt, buffer len = " . length ($buffer) . "\n")  if ($debug2) ;
                die "read_error reading headers ($!)" if ($cnt < 0) ;
                return if ($cnt == 0) ;
                }

            while ($buffer =~ s/^(.*?)\R//)
                {
                $line = $1 ;
                $self -> logger ("line=<$line>\n") if ($debug2) ;
                last header if ($line eq '') ;
                $header{$1} = $2 if ($line =~ /(.+?):\s*(.+)/) ;
                }
            $loop = 1 ;
            }

        my $len = $header{'Content-Length'} ;
        return 1 if ($len == 0);
        my $data ;
        #$self -> logger ("len=$len len buffer=", length ($buffer), "\n")  if ($debug2) ;
        while ($len > length ($buffer))
            {
            $cnt = $self -> _read (\$buffer, $len - length ($buffer), length ($buffer)) ;

            #$self -> logger ("cnt=$cnt len=$len len buffer=", length ($buffer), "\n")  if ($debug2) ;
            die "read_error reading data ($!)" if ($cnt < 0) ;
            return if ($cnt == 0) ;
            }
        if ($len == length ($buffer))
            {
            $data = $buffer ;
            $buffer = '' ;
            }
        elsif ($len < length ($buffer))
            {
            $data = substr ($buffer, 0, $len) ;
            $buffer = substr ($buffer, $len) ;
            }
        else
            {
            die "to few data bytes" ;
            }
        $self -> logger ("read data=", $data, "\n")  if ($debug2) ;
        $self -> logger ("read header=", dump (\%header), "\n")  if ($debug2) ;

        my $reqdata ;
        $reqdata = $json -> decode ($data) if ($data) ;
        if ($debug1)
            {
            $self -> logger ($self -> log_req_txt, $jsonpretty -> encode ($reqdata), "\n") ;
            }
        my $id = $reqdata -> {type}?-$reqdata -> {seq}:$reqdata -> {id};

        $self -> process_req ($id, $reqdata)  ;
        cede () ;
        }

    return 1 ;
    }

# ---------------------------------------------------------------------------

sub _run_tcp_server
    {
    my ($listen_port) = @_ ;

    if ($listen_port)
        {
        my $quit ;
        while (!$quit && !$exit)
            {
            logger (undef, "tcp server start listen on port $listen_port\n") ;
            my $tcpcv = AnyEvent::CondVar -> new ;
            my $guard ;
            eval
                {
                $guard = tcp_server '127.0.0.1', $listen_port, sub
                    {
                    my ($fh, $host, $port) = @_ ;

                    async
                        {
                        eval
                            {
                            $fh = Coro::Handle::unblock ($fh) ;
                            my $self = Perl::LanguageServer -> new ({out_fh => $fh, in_fh => $fh, log_prefix => 'DAx'});
                            $self -> logger ("connect from $host:$port\n") ;
                            $self -> listen_port ($listen_port) ;

                            $quit = $self -> mainloop () ;
                            $self -> logger ("got quit signal\n") if ($quit) ;
                            } ;
                        logger (undef, $@) if ($@) ;
                        if ($fh)
                            {
                            close ($fh) ;
                            $fh = undef ;
                            }
                        if ($quit || $exit)
                            {
                            $tcpcv -> send ;
                            IO::AIO::reinit () ; # stop AIO requests
                            exit (1) ;
                            }
                        } ;
                    } ;
                } ;
            if (!$@)
                {
                $tcpcv -> recv ;
                }
            else
                {
                $guard = undef ;
                logger (undef, $@) ;
                #$quit = 1 ;
                if (!$guard && ($@ =~ /Address already in use/))
                    {
                    # stop other server
                    tcp_connect '127.0.0.1', $listen_port, sub
                        {
                        my ($fh) = @_ ;
                        syswrite ($fh, "Content-Length: 0\r\n\r\n") if ($fh) ;
                        } ;
                    }
                $@ = undef ;
                Coro::AnyEvent::sleep (2) ;
                IO::AIO::reinit () ; # stop AIO requests
                exit (1) ; # stop LS, vscode will restart it
                }
            }
        }
    }

# ---------------------------------------------------------------------------

sub run
    {
    my $listen_port ;
    my $no_stdio ;
    my $heartbeat ;

    while (my $opt = shift @ARGV)
        {
        if ($opt eq '--debug')
            {
            $debug1 = $debug2 = 1  ;
            }
        elsif ($opt eq '--log-level')
            {
            $debug1 = shift @ARGV  ;
            $debug2 = $debug1 > 1?1:0 ;
            }
        elsif ($opt eq '--log-file')
            {
            $log_file = shift @ARGV ;
            }
        elsif ($opt eq '--port')
            {
            $listen_port = shift @ARGV  ;
            }
        elsif ($opt eq '--nostdio')
            {
            $no_stdio = 1  ;
            }
        elsif ($opt eq '--heartbeat')
            {
            $heartbeat = 1  ;
            }
        elsif ($opt eq '--version')
            {
            $client_version = shift @ARGV  ;
            }
        }

    $|= 1 ;

    my $cv = AnyEvent::CondVar -> new ;

    async
        {
        my $i = 0 ;
        while (1)
            {
            if ($heartbeat || $debug2)
                {
                logger (undef, "##### $i #####\n running: " . dump (\%running_reqs) . " coros: " . dump (\%running_coros), "\n") ;
                $i++ ;
                }

            Coro::AnyEvent::sleep (10) ;
            }
        } ;

    if (!$no_stdio)
        {
        async
            {
            my $self = Perl::LanguageServer -> new ({out_fh => 1, in_fh => 0});
            $self -> listen_port ($listen_port) ;

            $self -> mainloop () ;

            $cv -> send ;
            } ;
        }

    async
        {
        _run_tcp_server ($listen_port) ;
        } ;

    $cv -> recv ;
    $exit = 1 ;
    }

# ---------------------------------------------------------------------------

sub parsews
    {
    my $class = shift ;
    my @args = @_ ;

    $|= 1 ;

    my $cv = AnyEvent::CondVar -> new ;

    async
        {
        my $self = Perl::LanguageServer -> new ;
        $workspace = Perl::LanguageServer::Workspace -> new ({ config => {} }) ;
        my %folders ;
        foreach my $path (@args)
            {
            $folders{$path} = $path ;
            }
        $workspace -> folders (\%folders) ;
        $workspace -> background_parser ($self) ;

        $cv -> send ;
        } ;

    $cv -> recv ;
    }

# ---------------------------------------------------------------------------

sub check_file
    {
    my $class = shift ;
    my @args = @_ ;

    $|= 1 ;

    my $cv = AnyEvent::CondVar -> new ;

    my $self = Perl::LanguageServer -> new ;
    $workspace = Perl::LanguageServer::Workspace -> new ({ config => {} }) ;
    async
        {
        my %folders ;
        foreach my $path (@args)
            {
            $folders{$path} = $path ;
            }
        $workspace -> folders (\%folders) ;
        $workspace -> background_checker ($self) ;

        $cv -> send ;
        } ;

    async
        {
        foreach my $path (@args)
            {
            my $text ;
            aio_load ($path, $text) ;

            $workspace -> check_perl_syntax ($workspace, $path, $text) ;
            }

        } ;

    $cv -> recv ;
    }

1 ;

__END__

=head1 DOCUMENTATION

Language Server and Debug Protocol Adapter for Perl

=head2 Features

=over

=item * Language Server

=over

=item * Syntax checking

=item * Symbols in file

=item * Symbols in workspace/directory

=item * Goto Definition

=item * Find References

=item * Call Signatures

=item * Supports multiple workspace folders

=item * Document and selection formatting via perltidy

=item * Run on remote system via ssh

=item * Run inside docker container

=item * Run inside kubernetes

=back

=item * Debugger

=over

=item * Run, pause, step, next, return

=item * Support for coro threads

=item * Breakpoints

=item * Conditional breakpoints

=item * Breakpoints can be set while program runs and for modules not yet loaded

=item * Variable view, can switch to every stack frame or coro thread

=item * Set variable

=item * Watch variable

=item * Tooltips with variable values

=item * Evaluate perl code in debuggee, in context of every stack frame of coro thread

=item * Automatically reload changed Perl modules while debugging

=item * Debug multiple perl programs at once

=item * Run on remote system via ssh

=item * Run inside docker container

=item * Run inside kubernetes

=back

=back

=head2 Requirements

You need to install the perl module Perl::LanguageServer to make this extension work,
e.g. run C<cpan Perl::LanguageServer> on your target system.

Please make sure to always run the newest version of Perl::LanguageServer as well.

NOTE: Perl::LanguageServer depend on AnyEvent::AIO and Coro. There is a warning that
this might not work with newer Perls. It works fine for Perl::LanguageServer. So just
confirm the warning and install it.

Perl::LanguageServer depends on other Perl modules. It is a good idea to install most
of then with your linux package manager.

e.g. on Debian/Ubuntu run:


    
     sudo apt install libanyevent-perl libclass-refresh-perl libcompiler-lexer-perl \
     libdata-dump-perl libio-aio-perl libjson-perl libmoose-perl libpadwalker-perl \
     libscalar-list-utils-perl libcoro-perl
     
     sudo cpan Perl::LanguageServer
    

e.g. on Centos 7 run:


    
      sudo yum install perl-App-cpanminus perl-AnyEvent-AIO perl-Coro
      sudo cpanm Class::Refresh
      sudo cpanm Compiler::Lexer
      sudo cpanm Hash::SafeKeys
      sudo cpanm Perl::LanguageServer
    

In case any of the above packages are not available for your os version, just
leave them out. The cpan command will install missing dependencies. In case
the test fails, when running cpan C<install>, you should try to run C<force install>.

=head2 Extension Settings

This extension contributes the following settings:

=over

=item * C<perl.enable>: enable/disable this extension

=item * C<perl.sshAddr>: ip address of remote system

=item * C<perl.sshPort>: optional, port for ssh to remote system

=item * C<perl.sshUser>: user for ssh login

=item * C<perl.sshCmd>: defaults to ssh on unix and plink on windows

=item * C<perl.sshWorkspaceRoot>: path of the workspace root on remote system

=item * C<perl.perlCmd>: defaults to perl

=item * C<perl.perlArgs>: additional arguments passed to the perl interpreter that starts the LanguageServer

=item * C<useTaintForSyntaxCheck>: if true, use taint mode for syntax check

=item * C<perl.sshArgs>: optional arguments for ssh

=item * C<perl.pathMap>: mapping of local to remote paths

=item * C<perl.perlInc>: array with paths to add to perl library path. This setting is used by the syntax checker and for the debuggee and also for the LanguageServer itself.

=item * C<perl.fileFilter>: array for filtering perl file, defaults to [I<.pm,>.pl]

=item * C<perl.ignoreDirs>: directories to ignore, defaults to [.vscode, .git, .svn]

=item * C<perl.debugAdapterPort>: port to use for connection between vscode and debug adapter inside Perl::LanguageServer.

=item * C<perl.debugAdapterPortRange>: if debugAdapterPort is in use try ports from debugAdapterPort to debugAdapterPort + debugAdapterPortRange. Default 100.

=item * C<perl.showLocalVars>: if true, show also local variables in symbol view

=item * C<perl.logLevel>: Log level 0-2.

=item * C<perl.logFile>: If set, log output is written to the given logfile, instead of displaying it in the vscode output pane. Log output is always appended. Only use during debugging of LanguageServer itself.

=item * C<perl.disableCache>: If true, the LanguageServer will not cache the result of parsing source files on disk, so it can be used within readonly directories

=item * C<perl.containerCmd>: If set Perl::LanguageServer can run inside a container. Options are: 'docker', 'docker-compose', 'kubectl'

=item * C<perl.containerArgs>: arguments for containerCmd. Varies depending on containerCmd.

=item * C<perl.containerMode>: To start a new container, set to 'run', to execute inside an existing container set to 'exec'. Note: kubectl only supports 'exec'

=item * C<perl.containerName>: Image to start or container to exec inside or pod to use

=back

=head2 Debugger Settings for launch.json

=over

=item * C<type>: needs to be C<perl>

=item * C<request>: only C<launch> is supported (this is a restriction of perl itself)

=item * C<name>: name of this debug configuration

=item * C<program>: path to perl program to start

=item * C<stopOnEntry>: if true, program will stop on entry

=item * C<args>:   optional, array or string with arguments for perl program

=item * C<env>:    optional, object with environment settings

=item * C<cwd>:    optional, change working directory before launching the debuggee

=item * C<reloadModules>: if true, automatically reload changed Perl modules while debugging

=item * C<sudoUser>: optional, if set run debug process with sudo -u \<sudoUser\>.

=item * C<useTaintForDebug>: optional, if true run debug process with -T (taint mode).

=item * C<containerCmd>: If set debugger runs inside a container. Options are: 'docker', 'docker-compose', 'podman', 'kubectl'

=item * C<containerArgs>: arguments for containerCmd. Varies depending on containerCmd.

=item * C<containerMode>: To start a new container, set to 'run', to debug inside an existing container set to 'exec'. Note: kubectl only supports 'exec'

=item * C<containerName>: Image to start or container to exec inside or pod to use

=item * C<pathMap>: mapping of local to remote paths for this debug session (overwrites global C<perl.path_map>)

=back

=head2 Remote syntax check & debugging

If you developing on a remote machine, you can instruct the Perl::LanguageServer to
run on that remote machine, so the correct modules etc. are available for syntax check and debugger is started on the remote machine.
To do so set sshAddr and sshUser, preferably in your workspace configuration.

Example:


    "sshAddr": "10.11.12.13",
    "sshUser": "root"

Also set sshWorkspaceRoot, so the local workspace path can be mapped to the remote one.

Example: if your local path is \10.11.12.13\share\path\to\ws and on the remote machine you have /path/to/ws


    "sshWorkspaceRoot": "/path/to/ws"

The other possibility is to provide a pathMap. This allows one to having multiple mappings.

Examples:


    "perl.pathMap": [
        ["remote uri", "local uri"],
        ["remote uri", "local uri"]
    ]
    
    "perl.pathMap": [
        [
        "file:///",
        "file:///home/systems/mountpoint/"
        ]
    ]

=head2 Syntax check & debugging inside a container

You can run the LanguageServer and/or debugger inside
a container by setting C<containerCmd> and C<conatinerName>.
There are more container options, see above.

.vscode/settings.json


    {
        "perl": {
            "enable": true,
            "containerCmd": "docker",
            "containerName": "perl_container",
        }
    }

This will start the whole Perl::LanguageServer inside the container. This is espacally
helpfull to make syntax check working, if there is a different setup inside
and outside the container.

In this case you need to tell the Perl::LanguageServer how to map local paths
to paths inside the container. This is done by setting C<perl.pathMap> (see above).

Example:


    "perl.pathMap": [
        [
        "file:///path/inside/the/container",
        "file:///local/path/outside/the/container"
        ]
    ]

It's also possible to run the LanguageServer outside the container and only
the debugger inside the container. This is especially helpfull, when the
container is not always running, while you are editing. 
To make only the debugger running inside the container, put
C<containerCmd>, C<conatinerName> and C<pasth_map> in your C<launch.json>. 
You can have different setting for each debug session.

Normaly the arguments for the C<containerCmd> are automatically build. In case
you want to use an unsupported C<containerCmd> you need to specifiy
apropriate C<containerArgs>.

=head2 FAQ

=head3 Working directory is not defined

It is not defined what the current working directory is at the start of a perl program.
So Perl::LanguageServer makes no assumptions about it. To solve the problem you can set
the directory via cwd configuration parameter in launch.json for debugging.

=head3 Module not found when debugging or during syntax check

If you reference a module with a relative path or if you assume that the current working directory
is part of the Perl search path, it will not work.
Instead set the perl include path to a fixed absolute path. In your settings.json do something like:


        "perl.perlInc": [
            "/path/a/lib",
            "/path/b/lib",
            "/path/c/lib",
        ],
Include path works for syntax check and inside of debugger.
C<perl.perlInc> should be an absolute path.

=head3 AnyEvent, Coro Warning during install

You need to install the AnyEvent::IO and Coro. Just ignore the warning that it might not work. For Perl::LanguageServer it works fine.

=head3 'richterger.perl' failed: options.port should be >= 0 and < 65536

Change port setting from string to integer

=head3 Error "Can't locate MODULE_NAME"

Please make sure the path to the module is in C<perl.perlInc> setting and use absolute path names in the perlInc settings
or make sure you are running in the expected directory by setting the C<cwd> setting in the lauch.json.

=head3 ERROR: Unknown perlmethod I<rpcnot>setTraceNotification

This is not an issue, that just means that not all features of the debugging protocol are implemented.
Also it says ERROR, it's just a warning and you can safely ignore it.

=head3 The debugger sometimes stops at random places

Upgrade to Version 2.4.0

=head3 Message about Perl::LanguageServer has crashed 5 times

This is a problem when more than one instance of Perl::LanguageServer is running.
Upgrade to Version 2.4.0 solves this problem.

=head3 The program I want to debug needs some input via stdin

You can read stdin from a file during debugging. To do so add the following parameter
to your C<launch.json>:

C<< 
  "args": [ "E<lt>", "/path/to/stdin.txt" ]
 >>

e.g.

C<< 
{
    "type": "perl",
    "request": "launch",
    "name": "Perl-Debug",
    "program": "${workspaceFolder}/${relativeFile}",
    "stopOnEntry": true,
    "reloadModules": true,
    "env": {
        "REQUEST_METHOD": "POST",
        "CONTENT_TYPE": "application/x-www-form-urlencoded",
        "CONTENT_LENGTH": 34
    }
    "args": [ "E<lt>", "/path/to/stdin.txt" ]
}
 >>

=head3 Carton support

If you are using LL<https://metacpan.org/pod/Carton> to manage dependencies, add the full path to the Carton C<lib> dir to your workspace settings file at C<.vscode/settings.json>. For example:

=head4 Linux


    {
      "perl.perlInc": ["/home/myusername/projects/myprojectname/local/lib/perl5"]
    }

=head4 Mac


    {
      "perl.perlInc": ["/Users/myusername/projects/myprojectname/local/lib/perl5"]
    }

=head2 Known Issues

Does not yet work on windows, due to issues with reading from stdin.
I wasn't able to find a reliable way to do a non-blocking read from stdin on windows.
I would be happy, if anyone knows how to do this in Perl.

Anyway, Perl::LanguageServer runs without problems inside of Windows Subsystem for Linux (WSL).

=head2 Release Notes

see CHANGELOG.md

=head2 More Info

=over

=item * Presentation at German Perl Workshop 2020:

=back

https://github.com/richterger/Perl-LanguageServer/blob/master/docs/Perl-LanguageServer%20und%20Debugger%20f%C3%BCr%20Visual%20Studio%20Code%20u.a.%20Editoren%20-%20Perl%20Workshop%202020.pdf

=over

=item * Github: https://github.com/richterger/Perl-LanguageServer

=item * MetaCPAN: https://metacpan.org/release/Perl-LanguageServer

=back

For reporting bugs please use GitHub issues.

=head2 References

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

=head2 LICENSE AND COPYRIGHT

Copyright 2018-2022 Gerald Richter.

This program is free software; you can redistribute it and/or modify it
under the terms of the Artistic License (2.0). You may obtain a
copy of the full license at:

LL<http://www.perlfoundation.org/artistic_license_2_0>

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

=head1 Change Log

=head2 2.6.1   C<2023-07-26>

=over

=item * Fix: Formatting with perltidy was broken in 2.6.0

=back

=head2 2.6.0   C<2023-07-23>

=over

=item * Add debug setting for running as different user. See sudoUser setting. (#174) [wielandp]

=item * Allow to use a string for debuggee arguments. (#149, #173) [wielandp]

=item * Add stdin redirection (#166) [wielandp]

=item * Add link to issues to META files (#168) [szabgab/issues]

=item * Add support for podman

=item * Add support for run Perl::LanguageServer outside, but debugger inside a container

=item * Add setting useTaintForSyntaxCheck. If true, use taint mode for syntax check (#172) [wielandp]

=item * Add setting useTaintForDebug. If true, use taint mode inside debugger (#181) [wielandp]

=item * Add debug adapter request C<source>, which allows to display source of eval or file that are not available to vscode (#180) [wielandp]

=item * Fix: Spelling (#170, #171) [pkg-perl-tools]

=item * Fix: Convert charset encoding of debugger output according to current locale (#167) [wielandp]

=item * Fix: Fix diagnostic notifications override on clients (based on #185) [bmeneg]

=back

=head2 2.5.0   C<2023-02-05>

=over

=item * Set minimal Perl version to 5.16 (#91)

=item * Per default environment from vscode will be passed to debuggee, syntax check and perltidy.

=item * Add configuration C<disablePassEnv> to not pass environment variables.

=item * Support for C<logLevel> and C<logFile> settings via LanguageServer protocol and
not only via command line options (#97) [schellj]

=item * Fix: "No DB::DB routine defined" (#91) [peterdragon]

=item * Fix: Typos and spelling in README (#159) [dseynhae]

=item * Fix: Update call to gensym(), to fix 'strict subs' error (#164) [KohaAloha]

=item * Convert identention from tabs to spaces and remove trailing whitespaces 

=back

=head2 2.4.0   C<2022-11-18>

=over

=item * Choose a different port for debugAdapterPort if it is already in use. This
avoids trouble with starting C<Perl::LanguageServer> if another instance
of C<Perl::LanguageServer> is running on the same machine (thanks to hakonhagland)

=item * Add configuration C<debugAdapterPortRange>, for choosing range of port for dynamic
port assignment

=item * Add support for using LanguageServer and debugger inside a Container.
Currently docker containers und containers running inside kubernetes are supported.

=item * When starting debugger session and C<stopOnEntry> is false, do not switch to sourefile
where debugger would stop, when C<stopOnEntry> is true.

=item * Added some FAQs in README

=item * Fix: Debugger stopps at random locations

=item * Fix: debugAdapterPort is now numeric

=item * Fix: debugging loop with each statement (#107)

=item * Fix: display of arrays in variables pane on mac (#120)

=item * Fix: encoding for C<perltidy> (#127)

=item * Fix: return error if C<perltidy> fails, so text is not removed by failing
formatting request (#87)

=item * Fix: FindBin does not work when checking syntax (#16)

=back

=head2 2.3.0   C<2021-09-26>

=over

=item * Arguments section in Variable lists now C<@ARGV> and C<@_> during debugging (#105)

=item * C<@_> is now correctly evaluated inside of debugger console

=item * C<$#foo> is now correctly evaluated inside of debugger console

=item * Default debug configuration is now automatically provided without
the need to create a C<launch.json> first (#103)

=item * Add Option C<cacheDir> to specify location of cache dir (#113)

=item * Fix: Debugger outputted invalid thread reference causes "no such coroutine" message,
so watchs and code from the debug console is not expanded properly

=item * Fix: LanguageServer hangs when multiple request send at once from VSCode to LanguageServer

=item * Fix: cwd parameter for debugger in launch.json had no effect (#99)

=item * Fix: Correctly handle paths with drive letters on windows

=item * Fix: sshArgs parameter was not declared as array (#109)

=item * Disable syntax check on windows, because it blocks the whole process when running on windows,
until handling of child's processes is fixed

=item * Fixed spelling (#86,#96,#101) [chrstphrchvz,davorg,aluaces]

=back

=head2 2.2.0    C<2021-02-21>

=over

=item * Parser now supports Moose method modifieres before, after and around,
so they can be used in symbol view and within reference search

=item * Support Format Document and Format Selection via perltidy

=item * Add logFile config option

=item * Add perlArgs config option to pass options to Perl interpreter. Add some documentation for config options.

=item * Add disableCache config option to make LanguageServer usable with readonly directories.

=item * updated dependencies package.json & package-lock.json

=item * Fix deep recursion in SymbolView/Parser which was caused by function prototypes.
Solves also #65

=item * Fix duplicate req id's that caused cleanup of still
running threads which in turn caused the LanguageServer to hang

=item * Prevent dereferencing an undefined value (#63) [Heiko Jansen]

=item * Fix datatype of cwd config options (#47)

=item * Use perlInc setting also for LanguageServer itself (based only pull request #54 from ALANVF)

=item * Catch Exceptions during display of variables inside debugger

=item * Fix detecting duplicate LanguageServer processes

=item * Fix spelling in documentation (#56) [Christopher Chavez]

=item * Remove notice about Compiler::Lexer 0.22 bugs (#55) [Christopher Chavez]

=item * README: Typo and grammar fixes. Add Carton lib path instructions. (#40) [szTheory]

=item * README: Markdown code block formatting (#42) [szTheory]

=item * Makefile.PL: add META_MERGE with GitHub info (#32) [Christopher Chavez]

=item * search.cpan.org retired, replace with metacpan.org (#31) [Christopher Chavez]

=back

=head2 2.1.0    C<2020-06-27>

=over

=item * Improve Symbol Parser (fix parsing of anonymous subs)

=item * showLocalSymbols

=item * function names in breadcrump

=item * Signature Help for function/method arguments

=item * Add Presentation on Perl Workshop 2020 to repos

=item * Remove Compiler::Lexer from distribution since
version is available on CPAN

=item * Make stdout unbuffered while debugging

=item * Make debugger use perlInc setting

=item * Fix fileFilter setting

=item * Sort Arrays numerically in variables view of debugger

=item * Use rootUri if workspaceFolders not given

=item * Fix env config setting

=item * Recongnice changes in config of perlCmd

=back

=head2 2.0.2    C<2020-01-22>

=over

=item * Plugin: Fix command line parameters for plink

=item * Perl::LanguageServer: Fix handling of multiple parallel request, improve symlink handling, add support for UNC paths in path mapping, improve logging for logLevel = 1

=back

=head2 2.0.1    C<2020-01-14>

Added support for reloading Perl module while debugging, make log level configurable, make sure tooltips don't call functions

=head2 2.0.0    C<2020-01-01>

Added Perl debugger

=head2 0.9.0   C<2019-05-03>

Fix issues in the Perl part, make sure to update Perl::LanguageServer from cpan

=head2 0.0.3   C<2018-09-08>

Fix issue with not reading enough from stdin, which caused LanguageServer to hang sometimes

=head2 0.0.2  C<2018-07-21>

Fix quitting issue when starting Perl::LanguageServer, more fixes are in the Perl part

=head2 0.0.1  C<2018-07-13>

Initial Version
