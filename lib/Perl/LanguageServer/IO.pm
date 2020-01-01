package Perl::LanguageServer::IO ;

use Moose::Role ;

use Coro ;
use Coro::AIO ;
use Data::Dump qw{dump} ;

no warnings 'uninitialized' ;

has 'out_fh' => 
    (
    is => 'rw',
    #isa => 'Int',
    ) ;

has 'in_fh' => 
    (
    is => 'rw',
    #isa => 'Int',
    ) ;

# ---------------------------------------------------------------------------

our $windows=  ($^O =~ /Win/)?1:0 ;

# ---------------------------------------------------------------------------

sub _read 
    {
    my ($self, $data, $length, $dataoffset, $fh, $readline) = @_ ;

    $fh ||= $self -> in_fh ;

    if (ref ($fh) =~ /^Coro::Handle/)
        {
        if ($readline)
            {
            $$data = $fh -> readline ;
            return length ($$data) ;
            }
        return $fh -> sysread ($$data, $length, $dataoffset) ;
        }
    if (!$windows || !ref $fh)
        {
        return aio_read ($fh, undef, $length, $$data, $dataoffset) ;    
        }

    my $timeout = 0.01 ;

    my $s = IO::Select -> new ();
    $s -> add($fh) ;
    my @ready ;
    while (!(@ready = $s -> can_read (0)))
        {
        Coro::AnyEvent::sleep ($timeout) ;
        }
    $length = length ($$data) if (!defined ($length)) ;
    return sysread ($fh, $$data, $length, $dataoffset) ;
    }

# ---------------------------------------------------------------------------

sub _write 
    {
    my ($self, $data, $length, $dataoffset) = @_ ;

    my $fh = $self -> out_fh ;
    if (ref ($fh) =~ /^Coro::Handle/)
        {
        return $fh -> syswrite ($data, $length, $dataoffset) ;    
        }

    if (!$windows || !ref $fh)
        {
        return aio_write ($fh, undef, $length, $data, $dataoffset) ;    
        }

    $length = length ($data) if (!defined ($length)) ;
    return syswrite ($fh, $data, $length, $dataoffset) ;
    }

# ---------------------------------------------------------------------------

 sub run_async
    {
    my ($self, $cmd, $on_stdout, $on_stderr, $on_exit) = @_ ;

    $on_stdout ||= 'on_stdout' ;
    $on_stderr ||= 'on_stderr' ;
    $on_exit   ||= 'on_exit' ;

    my($wtr, $rdr, $err);
    
    $self -> logger ("start @$cmd\n") ;

    require IPC::Open3 ;
    require Symbol ; 
    $err = Symbol::gensym ;
    my $pid = IPC::Open3::open3($wtr, $rdr, $err, @$cmd) or die "Cannot run @$cmd" ;

    $self -> out_fh ($wtr) ;
    $self -> in_fh  ($rdr) ;

    $self -> logger ("@$cmd started\n") ;

    async
        {
        my $data ;
        while ($self -> _read (\$data, 8192))
            {
            $self -> logger ("stdout ", $data, "\n") ;
            $self -> $on_stdout ($data) ;    
            }    
        waitpid( $pid, 0 );
        $self -> logger ("@$cmd ended\n") ;
        Coro::cede_notself () ;
        $self -> $on_exit ($?)  ;    
        } ;
    
    async
        {
        my $data ;
        while ($self -> _read (\$data, 8192, undef, $err)) 
            {
            $self -> logger ("stderr ", $data, "\n") ;
            $self -> $on_stderr ($data) ;    
            }    
        } ;
    
    return $pid ;
    }


1 ;

