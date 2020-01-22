package Perl::LanguageServer;

use v5.18;

use strict ;
use Moose ;
use Moose::Util qw( apply_all_roles );

use Coro ;
use Coro::AIO ;
use Coro::Handle ;
use AnyEvent;
use AnyEvent::Socket ;
use JSON ;
use Data::Dump qw{dump} ;
use IO::Select ;

use Perl::LanguageServer::Req ; 
use Perl::LanguageServer::Workspace ;

with 'Perl::LanguageServer::Methods' ;
with 'Perl::LanguageServer::IO' ;

no warnings 'uninitialized' ;

=head1 NAME

Perl::LanguageServer - Language Server and Debug Protocol Adapter for Perl

=head1 VERSION

Version 2.0.1

=cut

our $VERSION = '2.0.2';


=head1 SYNOPSIS

This is a Language Server and Debug Protocol Adapter for Perl

It implements the Language Server Protocol which provides
syntax-checking, symbol search, etc. Perl to various editors, for
example Visual Stuido Code or Atom.

L<https://microsoft.github.io/language-server-protocol/specification>

It also implements the Debug Adapter Protocol, which allow debugging
with various editors/includes

L<https://microsoft.github.io/debug-adapter-protocol/overview>

To use both with Visual Studio Code, install the extention "perl"

Any comments and patches are welcome.

NOTE: This module uses Compiler::Lexer. The version on cpan (0.22) is buggy
crashes from time to time. For this reason a working version from github
is bundled with this module and will be installed when you run Makefile.PL.

L<https://github.com/goccy/p5-Compiler-Lexer>

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
our $client_version ;


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
    
    print STDERR $src?$src -> log_prefix . ': ':'', @_ ;    
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
        die "Unknown methd $method" ;    
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
    die "Unknow perlmethod $perlmethod" if (!$self -> can ($perlmethod)) ;

no strict ;
    return $self -> $perlmethod ($workspace, $req) ;
use strict ;    
    }

# ---------------------------------------------------------------------------

sub process_req
    {
    my ($self, $id, $reqdata) = @_ ;

    $running_coros{$id} = async
        {
        my $req_guard = Guard::guard 
            { 
            delete $running_reqs{$id} ;
            delete $running_coros{$id} ;
            };

        my $type   = $reqdata -> {type} ;
        my $is_dap = $type?1:0 ;
        $type      = defined ($id)?'request':'notification' if (!$type) ;
        $self -> logger ("handle_req id=$id\n") if ($debug1) ;
        my $req = Perl::LanguageServer::Req  -> new ({ id => $id, is_dap => $is_dap, type => $type, params => $is_dap?$reqdata -> {arguments} || {}:$reqdata -> {params}}) ;
        $running_reqs{$id} = $req ;

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
        cede () ;
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
            $self -> logger ("start aio read\n")  if ($debug2) ;
            $cnt = $self -> _read (\$buffer, 8192, length ($buffer), undef, 1) ;
            $self -> logger ("end aio read cnt=$cnt\n")  if ($debug2) ;
            die "read_error reading headers ($!)" if ($cnt < 0) ;
            return if ($cnt == 0) ;

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
                        $tcpcv -> send if ($quit || $exit);
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
                Coro::AnyEvent::sleep (1) ;
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

   if ($heartbeat)
        {
        async
            {
            my $i = 0 ;
            while (1)
                {
                print STDERR "#####$i\n" ;
                Coro::AnyEvent::sleep (3) ;
                $i++ ;
                }
            } ;
        }
   
    if (!$no_stdio)
        {
        async
            {    
            my $self = Perl::LanguageServer -> new ({out_fh => 1, in_fh => 0});

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






=pod



=head1 AUTHOR

grichter, C<< <richter at ecos.de> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-perl-languageserver at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Perl-LanguageServer>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Perl::LanguageServer


You can also look for information at:

=over 4

=item * Github:
 L<https://github.com/richterger/Perl-LanguageServer>

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Perl-LanguageServer>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Perl-LanguageServer>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Perl-LanguageServer>

=item * Search CPAN

L<http://search.cpan.org/dist/Perl-LanguageServer/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2018-2020 grichter.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
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


=cut

1; # End of Perl::LanguageServer
