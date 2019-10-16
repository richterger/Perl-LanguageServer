package Perl::LanguageServer::Methods::DebugAdapterInterface ;

use Moose::Role ;

use Coro ;
use Coro::AIO ;
use Data::Dump qw{dump} ;
use Perl::LanguageServer::DevTool ;
use Perl::LanguageServer::DebuggerProcess ;

no warnings 'uninitialized' ;

# ---------------------------------------------------------------------------

has 'debugger_process' =>
    (
    isa => 'Perl::LanguageServer::DebuggerProcess',
    is  => 'rw' 
    ) ; 

has 'debug_adapter' =>
    (
    isa => 'Perl::LanguageServer',
    is  => 'rw',
    weak_ref => 1, 
    ) ; 

has 'channel' =>
    (
    is => 'ro',
    isa => 'Coro::Channel',
    default => sub { Coro::Channel -> new }    
    ) ;

has 'initialized' =>
    (
    is => 'rw',
    isa => 'Bool',
    default => 0    
    ) ;

# ---------------------------------------------------------------------------

sub send_event
    {
    my ($self, $event, $body) = @_ ;

    $self -> debug_adapter -> send_event ($event, $body) ;
    }

# ---------------------------------------------------------------------------

sub request
    {
    my ($self, $req) = @_ ;

    $self -> send_notification ($req) ;

    return $self -> channel -> get ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_di_response
    {
    my ($self, $workspace, $req) = @_ ;

    #$self -> logger ("di_response params = ", dump($req -> params), "\n") ;

    $self -> channel -> put ($req -> params) ;
    return ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_di_break
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> log_prefix ('DAI') ;

    my $debug_adapter = $Perl::LanguageServer::Methods::DebugAdapter::debug_adapters{$req -> params -> {session_id}} ;
    die "no debug_adapter for session " . $req -> params -> {session_id} if (!$debug_adapter) ;

    $self -> logger ("session_id = " . $req -> params -> {session_id} . "\n") ;
    $self -> logger ("debug_adapter = ", dump ($debug_adapter), "\n") ;

    $self -> debug_adapter ($debug_adapter) ;
    $self -> debugger_process ($debug_adapter -> debugger_process) ;
    $debug_adapter -> debug_adapter_interface ($self) ;

    my $initialized = $self -> initialized ;
    my $reason      = $req -> params -> {reason} ;
    $reason         ||= $initialized?'breakpoint':'entry' ;

    $self -> send_event ('stopped', 
                        { 
                        reason => $reason,
                        threadId => 1,
                        #preserveFocusHint => JSON::true (),
                        allThreadsStopped => JSON::true (),
                        }) ;

    if (!$initialized)
        {
        $self -> send_event ('initialized') ;
        }

    $self -> initialized (1) ;

    return ;
    }

1 ;
