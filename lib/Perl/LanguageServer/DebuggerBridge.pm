package Perl::LanguageServer::DebuggerBridge ;

use 5.006;
use strict;
use IO::Socket ;
use IO::Select;

no warnings 'uninitialized' ;

sub run
    {
    my $socket ;
    my $proto = getprotobyname ('tcp') ;
    my $ip = '127.0.0.1' ;
    my $port = $ARGV[0] || 13603 ;
    socket ($socket, PF_INET, SOCK_STREAM, $proto)
        or die "Can't create a socket $!\n" ;
    connect ($socket, pack_sockaddr_in ($port, inet_aton ($ip)))
        or die "Can't connect to $ip:$port $!\n"  ;
    my $stdin = \*STDIN ;
    my $s = IO::Select->new();
    $s->add($stdin);
    $s->add($socket);

    my $timeout = 0 ;
    my @ready ;
    while (@ready = $s->can_read())
        {
        while (my $fh = shift @ready)
            {
            if ($fh == $stdin)
                {
                my $data ;
                exit if (sysread ($fh, $data, 16384) <= 0) ;
                syswrite ($socket, $data) ;
                }
            elsif ($fh == $socket)
                {
                my $data ;
                exit if (sysread ($fh, $data, 16384) <= 0) ;
                syswrite (\*STDOUT, $data) ;
                }
            }
        }
    }

1 ;