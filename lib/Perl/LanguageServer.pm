package Perl::LanguageServer;

use strict ;
use Moose ;
use Moose::Util qw( apply_all_roles );

use Coro ;
use Coro::AIO ;
use AnyEvent;
use JSON ;
use Data::Dump qw{dump} ;

use Perl::LanguageServer::Req ; 
use Perl::LanguageServer::Workspace ;

with 'Perl::LanguageServer::Methods' ;


no warnings 'uninitialized' ;

=head1 NAME

Perl::LanguageServer - Language Server for Perl

=head1 VERSION

Version 0.03

=cut

our $VERSION = '0.03';


=head1 SYNOPSIS

This is a Language Server for Perl

It implements the Language Server Protocol which provides
syntax-checking, symbol search, etc. Perl to various editors, for
example Visual Stuido Code or Atom.

https://microsoft.github.io/language-server-protocol/specification

To use it with Visual Studio Code, install the extention "perl"

This is an early version, but already working version.
Any comments and patches are welcome.

NOTE: This module uses Compiler::Lexer. The version on cpan (0.22) is buggy
crashes from time to time. Please use the version from github 
(https://github.com/goccy/p5-Compiler-Lexer) until
a new version is published to cpan.

=cut

our $json = JSON -> new -> utf8(1) -> ascii(1) ;

our %running_reqs ;
our %running_coros ;
our $exit ;
our $workspace ;
our $debug1 = 1 ;
our $debug2 = 0 ;


has 'channel' =>
    (
    is => 'ro',
    isa => 'Coro::Channel',
    default => sub { Coro::Channel -> new }    
    ) ;

has 'client_fh' =>
    (
    is => 'rw',
    isa => 'AnyEvent::Handle',
    ) ;

has 'debug' =>
    (
    is => 'rw',
    isa => 'Int',
    default => 1,
    ) ;

has 'out_semaphore' =>
    (
    is => 'ro',
    isa => 'Coro::Semaphore',
    default => sub { Coro::Semaphore -> new }
    ) ;

# ---------------------------------------------------------------------------

sub logger
    {
    print STDERR @_ ;    
    }

# ---------------------------------------------------------------------------

sub send_notification 
    {
    my ($self, $notification) = @_ ;

    $notification -> {jsonrpc} = '2.0' ;       
    my $outdata = $json -> encode ($notification) ;
    my $guard = $self -> out_semaphore -> guard  ;
    use bytes ;
    my $len  = length($outdata) ;
    #$self -> client_fh -> push_write ("Content-Length: $len\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n$outdata") ;
    aio_write (1, undef, undef, "Content-Length: $len\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n$outdata", 0) ;
    print STDERR "Content-Length: $len\nContent-Type: application/vscode-jsonrpc; charset=utf-8\n\n$outdata\n" if ($debug2) ;

    }

# ---------------------------------------------------------------------------

sub call_method 
    {
    my ($self, $reqdata, $req, $id) = @_ ;

    my $method = $reqdata -> {method} ;
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

    #print STDERR "mod=$module name=$name\n" ;
    my $base_package = __PACKAGE__ . '::Methods' ;
    my $package = $base_package ;
    $package .= '::' . $module if ($module) ;

    #print STDERR "package=$package\n" ;
    my $fn = $package . '.pm' ;
    $fn =~ s/::/\//g ;
    if (!exists $INC{$fn})
        {
        print STDERR dump (\%INC), "\n" ;
        print STDERR "apply_all_roles ($self, $package, $fn)\n" ;
        apply_all_roles ($self, $package) ;
            
        #eval "require $package" ;
        #die $@ if ($@) ;   
        }

    #my $func = $package . (defined($id)?'::_rpcreq_':'::_rpcnot_') . $name ;
    my $perlmethod = (defined($id)?'_rpcreq_':'_rpcnot_') . $name ;
    print STDERR "method=$perlmethod\n" if ($debug1) ;
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

        print STDERR "handle_req id=$id\n" if ($debug1) ;
        my $req = Perl::LanguageServer::Req  -> new ({ id => $id, params => $reqdata -> {params}}) ;
        $running_reqs{$id} = $req ;

        my $rsp ;
        my $outdata ;
        eval
            {
            $rsp = $self -> call_method ($reqdata, $req, $id) ;

            $outdata = $json -> encode ({ id => $id, jsonrpc => '2.0', result => $rsp})  if ($rsp) ;
            #print STDERR dump ({ id => $id, jsonrpc => '2.0', result => $rsp}), "\n" ;
            #print STDERR dump ($outdata), "\n" ;

            } ;
        if ($@)
            {
            print STDERR "ERROR: $@\n" ;
            $outdata = $json -> encode ({ id => $id, jsonrpc => '2.0', error => { code => -32001, message => "$@" }}) ;
            }

        if (defined($id))
            {
            my $guard = $self -> out_semaphore -> guard  ;
            use bytes ;
            my $len  = length ($outdata) ;
            #$self -> client_fh -> push_write ("Content-Length: $len\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n$outdata") ;
            my $wrdata = "Content-Length: $len\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n$outdata" ;
            my $sum = 0 ;
            my $cnt ;
            while ($sum < length ($wrdata))
                {
                $cnt = aio_write (1, undef, undef, $wrdata, $sum) ;
                die "write_error ($!)" if ($cnt <= 0) ;
                $sum += $cnt ;
                }

            print STDERR "Content-Length: $len\nContent-Type: application/vscode-jsonrpc; charset=utf-8\n\n$outdata\n" if ($debug2) ;
            }
        cede () ;
        } ;

    }

# ---------------------------------------------------------------------------

sub mainloop
    {
    my ($self) = @_ ;

    my $fh = 0 ;
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
            if (!$loop && length ($buffer) == 0)
                {
                print STDERR "start aio read\n" ;
                $cnt = aio_read $fh, undef, 8192, $buffer, length ($buffer) ;
                #$cnt = sysread STDIN, $buffer, 10000, length ($buffer) ;
                print STDERR "end aio read cnt=$cnt\n" ;
                die "read_error reading headers" if ($cnt < 0) ;
                return if ($cnt == 0) ;
                }

            while ($buffer =~ s/^(.*?)\R//)
                {
                $line = $1 ;    
                print STDERR "line=<$line>\n" if ($debug2) ;
                last header if ($line eq '') ;
                $header{$1} = $2 if ($line =~ /(.+?):\s*(.+)/) ;
                }
            $loop = 1 ;
            }

        my $len = $header{'Content-Length'} ;
        my $data ;
        print STDERR "len=$len len buffer=", length ($buffer), "\n" ;
        while ($len > length ($buffer)) 
            {
            $cnt = aio_read $fh, undef, $len - length ($buffer), $buffer, length ($buffer);
            print STDERR "cnt=$cnt len=$len len buffer=", length ($buffer), "\n" ;
            die "read_error reading data" if ($cnt < 0) ;
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
        print STDERR $data, "\n" ;
        print STDERR "header=", dump (\%header), "\n" ;

        my $reqdata ;
        $reqdata = $json -> decode ($data) if ($data) ;
        print STDERR dump ($reqdata), "\n" if ($debug2) ;

        my $id = $reqdata -> {id} ;
        #print STDERR "id=$id\n" ;

        $self -> process_req ($id, $reqdata)  ;
        cede () ;
        } 

    }


# ---------------------------------------------------------------------------

sub run
    {
    $debug2 = 1 if ($ARGV[0] eq '--debug') ;    

    $|= 1 ;
    
    my $cv = AnyEvent::CondVar -> new ;

   async
        {
        my $i = 0 ;
        while (0)
            {
            print STDERR "#####$i\n" ;
            Coro::AnyEvent::sleep (3) ;
            $i++ ;
            }
        } ;
   
    async
        {    
        my $self = Perl::LanguageServer -> new ;

        #$self -> run_server ;

        $self -> mainloop ;

        $cv -> send ;
        } ;

    $cv -> recv ;    
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

Copyright 2018 grichter.

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
