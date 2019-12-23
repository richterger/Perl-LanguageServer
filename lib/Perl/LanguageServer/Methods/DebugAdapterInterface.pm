package Perl::LanguageServer::Methods::DebugAdapterInterface ;

use Moose::Role ;

use Coro ;
use Coro::AIO ;
use Data::Dump qw{dump} ;
use Perl::LanguageServer::DevTool ;
use Perl::LanguageServer::DebuggerProcess ;

no warnings 'uninitialized' ;

our $reqseq = 1 ;

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
    predicate => 'has_debug_adapter',
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

has 'responses' =>
    (
    isa => 'HashRef',
    is  => 'rw',
    default => sub { {} },
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

    my $seq = $reqseq++ ;
    $req -> {seq} = $seq ;

    my $channels = $self -> responses ;
    local $channels -> {$seq} = Coro::Channel -> new ;
    
    $self -> send_notification ($req) ;

    return $channels -> {$seq} -> get ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_di_response
    {
    my ($self, $workspace, $req) = @_ ;

    my $seq = - $req -> id ;
    my $channels = $self -> responses ;
    $self -> logger ("di_response seq = $seq channels = ", dump($channels), "\n") ;
    return if (!exists $channels -> {$seq}) ;
    $channels -> {$seq} -> put ($req -> params) ;
    return ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_di_break
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> log_prefix ('DAI') ;

    my $debug_adapter = $Perl::LanguageServer::Methods::DebugAdapter::debug_adapters{$req -> params -> {session_id}} ;
    die "no debug_adapter for session " . $req -> params -> {session_id} if (!$debug_adapter) ;
    $debug_adapter -> running (0) ;
    
    $self -> logger ("session_id = " . $req -> params -> {session_id} . "\n") ;
    #$self -> logger ("debug_adapter = ", dump ($debug_adapter), "\n") ;

    $self -> debug_adapter ($debug_adapter) ;
    $self -> debugger_process ($debug_adapter -> debugger_process) ;
    $debug_adapter -> debug_adapter_interface ($self) ;

    my $initialized = $self -> initialized ;
    my $reason      = $req -> params -> {reason} ;
print STDERR "reason = $reason tempb = ", $debug_adapter -> in_temp_break, "\n" ;
    return if ($reason eq 'pause' && $debug_adapter -> in_temp_break) ;
    $debug_adapter -> in_temp_break (0) ;

    $reason         ||= $initialized?'breakpoint':'entry' ;

    $debug_adapter -> clear_non_thread_ids ;

    $self -> send_event ('stopped', 
                        { 
                        reason => $reason,
                        threadId => $debug_adapter -> getid (0, $req -> params -> {thread_ref}) || 1,
                        preserveFocusHint => JSON::false (),
                        allThreadsStopped => JSON::true (),
                        }) ;

    if (!$initialized)
        {
        $self -> send_event ('initialized') ;
        }

    $self -> initialized (1) ;

    return ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_di_loadedfile
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> log_prefix ('DAI') ;

    if (!$self -> has_debug_adapter)
        {
        my $debug_adapter = $Perl::LanguageServer::Methods::DebugAdapter::debug_adapters{$req -> params -> {session_id}} ;
        die "no debug_adapter for session " . $req -> params -> {session_id} if (!$debug_adapter) ;

        $self -> logger ("session_id = " . $req -> params -> {session_id} . "\n") ;
        $self -> logger ("debug_adapter = ", dump ($debug_adapter), "\n") ;

        $self -> debug_adapter ($debug_adapter) ;
        $self -> debugger_process ($debug_adapter -> debugger_process) ;
        $debug_adapter -> debug_adapter_interface ($self) ;
        }


    $self -> send_event ('loadedSource', 
                        { 
                        reason => $req -> params -> {reason},
                        source => $req -> params -> {source},
                        }) ;

    return ;
    }

# ---------------------------------------------------------------------------

sub _dapreq_di_breakpoints
    {
    my ($self, $workspace, $req) = @_ ;

    $self -> log_prefix ('DAI') ;

    foreach my $bp (@{$req -> params -> {breakpoints}})
        {
        $self -> send_event ('breakpoint', 
                        { 
                        reason => 'changed',
                        breakpoint => 
                            {
                            verified => $bp -> [2]?JSON::true ():JSON::false (),
                            message  => $bp -> [3], 
                            line     => $bp -> [4]+0,
                            id       => $bp -> [6]+0,
                            source   => { path => $workspace -> file_server2client ($bp -> [5]) },
                            }
                        }) ;
        }

    return ;
    }

# ---------------------------------------------------------------------------

1 ;
